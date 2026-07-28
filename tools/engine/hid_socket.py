#!/usr/bin/env python3
"""Unix domain socket HID control — low-latency alternative to HTTP loopback.

Protocol (v1) — write-only
--------------------------
The Mac client writes framed commands and never waits for a reply. Bytes
accepted by the kernel only mean *queued for the per-connection worker*,
not *delivered to Indigo / UniversalHID*. There is no 0xFF ACK; earlier
ACK-per-command designs caused asyncio ``socket.send() raised exception``
spam after half-close (post-``conn_lost`` writes warn forever without raising).

On disconnect the worker **drains** already-queued work (with a timeout)
instead of cancelling mid-flight, so a client that writes and closes does
not silently lose buttons/keys that were already accepted onto the socket.

Touch moves coalesce (latest contact wins). Touch and non-touch jobs share
the worker fairly so a drag cannot starve the keyboard. Queues are bounded.
Auth is filesystem mode ``0600`` on the socket path (loopback UDS only).
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import struct
from collections import deque
from typing import Awaitable, Callable, Deque, Optional, Tuple

LOG = logging.getLogger("mirrorue.hid")

HID_PATH = os.environ.get("MIRRORUE_HID_SOCK", "/tmp/mirrorue_hid.sock")
PROTOCOL_VERSION = 1

CMD_TOUCH = 0x01
CMD_BUTTON = 0x02
CMD_INSTANT = 0x03
CMD_MUSIC = 0x04
CMD_KEY = 0x05
CMD_KEYBOARD_RESET = 0x06

# Soft caps — excess touch contacts coalesce; excess jobs are dropped (logged).
MAX_PENDING = max(8, int(os.environ.get("MIRRORUE_HID_PENDING", "64")))
MAX_TOUCH = max(2, int(os.environ.get("MIRRORUE_HID_TOUCH", "8")))
DRAIN_TIMEOUT_S = max(0.05, float(os.environ.get("MIRRORUE_HID_DRAIN_S", "2.0")))
JOB_TIMEOUT_S = max(0.05, float(os.environ.get("MIRRORUE_HID_JOB_S", "5.0")))

TouchHandler = Callable[[str, int, int], Awaitable[None]]
ButtonHandler = Callable[[str, str], Awaitable[None]]
InstantHandler = Callable[[bool], Awaitable[None]]
MusicHandler = Callable[[bool], Awaitable[None]]
# down, usage (0 if char path), utf-8 character (may be empty), mods bitmask
KeyHandler = Callable[[bool, int, str, int], Awaitable[None]]
ResetHandler = Callable[[], Awaitable[None]]

MOD_SHIFT = 0x01
MOD_CTRL = 0x02
MOD_ALT = 0x04
MOD_GUI = 0x08

TouchEvent = Tuple[str, int, int]


class HidSocketServer:
    def __init__(self, path: str = HID_PATH) -> None:
        self._path = path
        self._server: Optional[asyncio.AbstractServer] = None
        self._touch: Optional[TouchHandler] = None
        self._button: Optional[ButtonHandler] = None
        self._instant: Optional[InstantHandler] = None
        self._music: Optional[MusicHandler] = None
        self._key: Optional[KeyHandler] = None
        self._reset: Optional[ResetHandler] = None

    def bind(
        self,
        *,
        touch: TouchHandler,
        button: ButtonHandler,
        instant: InstantHandler,
        music: MusicHandler,
        key: Optional[KeyHandler] = None,
        reset: Optional[ResetHandler] = None,
    ) -> None:
        self._touch = touch
        self._button = button
        self._instant = instant
        self._music = music
        self._key = key
        self._reset = reset

    async def start(self) -> None:
        if os.path.exists(self._path):
            with contextlib.suppress(OSError):
                os.unlink(self._path)
        self._server = await asyncio.start_unix_server(self._handle, path=self._path)
        os.chmod(self._path, 0o600)
        LOG.info(
            "HID socket %s protocol=v%d pending≤%d touch≤%d drain=%.1fs",
            self._path,
            PROTOCOL_VERSION,
            MAX_PENDING,
            MAX_TOUCH,
            DRAIN_TIMEOUT_S,
        )

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        if os.path.exists(self._path):
            with contextlib.suppress(OSError):
                os.unlink(self._path)

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        pending: Deque[Awaitable[None]] = deque()
        touch_buf: Deque[TouchEvent] = deque()
        wake = asyncio.Event()
        closed = False
        dropped_jobs = 0
        fail_streak = [0]  # mutable cell shared with run_logged
        peer = writer.get_extra_info("peername") or self._path

        def enqueue_touch(typ: str, x: int, y: int) -> None:
            if typ == "contact" and touch_buf and touch_buf[-1][0] == "contact":
                touch_buf[-1] = (typ, x, y)
                return
            if len(touch_buf) >= MAX_TOUCH:
                # Drop oldest non-release if possible; never drop a trailing release.
                if touch_buf and touch_buf[0][0] == "contact":
                    touch_buf.popleft()
                elif len(touch_buf) >= MAX_TOUCH:
                    LOG.warning("HID touch queue full (%s); dropping %s", peer, typ)
                    return
            touch_buf.append((typ, x, y))

        def enqueue_job(job: Awaitable[None]) -> None:
            nonlocal dropped_jobs
            if len(pending) >= MAX_PENDING:
                dropped_jobs += 1
                if dropped_jobs == 1 or dropped_jobs % 32 == 0:
                    LOG.warning(
                        "HID job queue full (%s); dropped %d job(s)",
                        peer,
                        dropped_jobs,
                    )
                return
            pending.append(job)

        async def run_logged(label: str, coro: Awaitable[None]) -> None:
            try:
                await asyncio.wait_for(coro, timeout=JOB_TIMEOUT_S)
                fail_streak[0] = 0
            except asyncio.TimeoutError:
                LOG.warning("HID %s timed out after %.1fs (%s)", label, JOB_TIMEOUT_S, peer)
            except asyncio.CancelledError:
                raise
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, asyncio.IncompleteReadError, EOFError) as exc:
                fail_streak[0] += 1
                n = fail_streak[0]
                # Drop queued touches so a dead tunnel cannot enqueue forever.
                if touch_buf:
                    touch_buf.clear()
                if n == 1 or n % 25 == 0:
                    LOG.warning(
                        "HID %s transport error ×%d (%s): %s — clearing touch queue",
                        label,
                        n,
                        peer,
                        exc,
                    )
            except OSError as exc:
                fail_streak[0] += 1
                n = fail_streak[0]
                if touch_buf:
                    touch_buf.clear()
                if n == 1 or n % 25 == 0:
                    LOG.warning("HID %s OSError ×%d (%s): %s", label, n, peer, exc)
            except Exception:
                fail_streak[0] += 1
                n = fail_streak[0]
                if n == 1 or n % 25 == 0:
                    LOG.exception("HID %s failed ×%d (%s)", label, n, peer)

        async def worker() -> None:
            """Fair drain: one touch then one job per lap; finish queues after close."""
            while True:
                if closed and not pending and not touch_buf:
                    return

                progressed = False

                if touch_buf and self._touch:
                    typ, x, y = touch_buf.popleft()
                    await run_logged(f"touch:{typ}", self._touch(typ, x, y))
                    progressed = True

                if pending:
                    job = pending.popleft()
                    await run_logged("job", job)
                    progressed = True

                if progressed:
                    continue

                if closed:
                    return

                wake.clear()
                # Re-check after clear to avoid missing a wake between empty and wait.
                if pending or touch_buf or closed:
                    continue
                try:
                    await wake.wait()
                except asyncio.CancelledError:
                    if closed:
                        # Final cancel after drain timeout — exit cleanly.
                        return
                    raise

        worker_task = asyncio.create_task(worker(), name="mirrorue-hid-worker")
        try:
            while True:
                cmd = (await reader.readexactly(1))[0]
                if cmd == CMD_TOUCH and self._touch:
                    body = await reader.readexactly(5)
                    typ = "contact" if body[0] else "release"
                    x, y = struct.unpack("<HH", body[1:5])
                    enqueue_touch(typ, x, y)
                    wake.set()
                elif cmd == CMD_BUTTON and self._button:
                    nlen = (await reader.readexactly(1))[0]
                    name = (await reader.readexactly(nlen)).decode("utf-8", "replace")
                    state = "press" if (await reader.readexactly(1))[0] else "release"
                    enqueue_job(self._button(name, state))
                    wake.set()
                elif cmd == CMD_INSTANT and self._instant:
                    hard = bool((await reader.readexactly(1))[0])
                    enqueue_job(self._instant(hard))
                    wake.set()
                elif cmd == CMD_MUSIC and self._music:
                    on = bool((await reader.readexactly(1))[0])
                    enqueue_job(self._music(on))
                    wake.set()
                elif cmd == CMD_KEY and self._key:
                    head = await reader.readexactly(5)
                    flags, usage, mods, clen = struct.unpack("<BHBB", head)
                    char = (
                        (await reader.readexactly(clen)).decode("utf-8", "replace")
                        if clen
                        else ""
                    )
                    down = bool(flags & 1)
                    enqueue_job(self._key(down, int(usage), char, int(mods)))
                    wake.set()
                elif cmd == CMD_KEYBOARD_RESET and self._reset:
                    enqueue_job(self._reset())
                    wake.set()
                else:
                    LOG.warning("HID unknown cmd=0x%02x from %s — closing", cmd, peer)
                    break
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass
        except asyncio.CancelledError:
            raise
        except OSError as exc:
            LOG.debug("HID reader error (%s): %s", peer, exc)
        finally:
            # Stop accepting; let the worker finish what was already queued.
            closed = True
            wake.set()
            try:
                await asyncio.wait_for(asyncio.shield(worker_task), timeout=DRAIN_TIMEOUT_S)
            except asyncio.TimeoutError:
                LOG.warning(
                    "HID worker drain timed out (%s); pending=%d touch=%d — cancelling",
                    peer,
                    len(pending),
                    len(touch_buf),
                )
                worker_task.cancel()
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await worker_task
            except Exception:
                LOG.exception("HID worker drain failed (%s)", peer)
                worker_task.cancel()
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await worker_task

            if dropped_jobs:
                LOG.info("HID session %s dropped %d job(s) to queue limits", peer, dropped_jobs)

            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
