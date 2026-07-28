#!/usr/bin/env python3
"""MUVS/3 — MirrorUE Video over Unix Socket, shared-memory edition.

The engine's whole per-frame cost is one `memmove` from the VideoToolbox pixel
buffer into a shared-memory slot. There is no rescale, no pixel comparison, no
intermediate `bytes`, and no event-loop hop: the decoder thread copies and
writes a 15-byte message to the socket itself. The UI maps the same memory and
builds Metal textures over it, so the GPU samples these bytes directly.

Flow control stays credit based. The UI acknowledges a frame once the GPU has
finished reading its slot, which both returns a credit and makes slot recycling
safe. When no credit is available the decoder skips the copy entirely, so a
throttled or hidden UI costs the engine almost nothing.

  client → HELLO
  server → BIND   (+ ring fd via SCM_RIGHTS)   [re-sent when geometry changes]
  server → FRAME  (seq, slot)
  client → ACK    (seq, displayed_ns)
"""

from __future__ import annotations

import asyncio
import contextlib
import ctypes
import logging
import os
import socket
import struct
import threading
import time
from collections import deque
from typing import Deque, Dict, Optional

from muvs_shm import HEADER, MAGIC, ShmRing

LOG = logging.getLogger("mirrorue.video")

VIDEO_PATH = os.environ.get("MIRRORUE_VIDEO_SOCK", "/tmp/mirrorue_video.sock")
SHM_PATH = os.environ.get("MIRRORUE_VIDEO_SHM", "/tmp/mirrorue_video.shm")
CREDITS = max(1, int(os.environ.get("MIRRORUE_MUVS_CREDITS", "2")))
# One slot to write into plus one per unacknowledged frame.
SLOTS = max(CREDITS + 1, int(os.environ.get("MIRRORUE_MUVS_SLOTS", "4")))

PROTOCOL_VERSION = 3

MSG_HELLO = 0x01
MSG_BIND = 0x11
MSG_FRAME = 0x20
MSG_ACK = 0x30

HELLO = struct.Struct("<B4sHH")  # type magic version features           = 9
BIND = struct.Struct("<B4sHHIIHHIH")  # type magic version slots stride
#                                       slot_bytes w h header path_len  = 27
FRAME = struct.Struct("<BIHQ")  # type seq slot produced_ns             = 15
ACK = struct.Struct("<BIQ")  # type seq displayed_ns                    = 13


class _Window:
    __slots__ = ("_values", "_lock")

    def __init__(self, cap: int = 512) -> None:
        self._values: Deque[float] = deque(maxlen=cap)
        self._lock = threading.Lock()

    def add_ms(self, ms: float) -> None:
        with self._lock:
            self._values.append(ms)

    def snapshot(self) -> Dict[str, float]:
        with self._lock:
            if not self._values:
                return {"p50_ms": 0.0, "p95_ms": 0.0, "samples": 0.0}
            ordered = sorted(self._values)
            n = len(ordered)
            return {
                "p50_ms": round(ordered[n // 2], 3),
                "p95_ms": round(ordered[int(n * 0.95)] if n > 1 else ordered[-1], 3),
                "samples": float(n),
            }


class VideoSocketPublisher:
    """Engine side of MUVS/3 — pairs with MediaKit VideoSocketReader."""

    def __init__(self, path: str = VIDEO_PATH, shm_path: str = SHM_PATH) -> None:
        self._path = path
        self._shm_path = shm_path
        self._server: Optional[asyncio.AbstractServer] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._sock: Optional[socket.socket] = None

        self._lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._ring: Optional[ShmRing] = None
        self._ring_generation = 0
        self._bound_generation = -1
        self._inflight: Dict[int, int] = {}
        self._credits = 0
        self._seq = 0

        self._sent = 0
        self._skipped_nocredit = 0
        self._row_by_row = 0
        self._copy = _Window()
        self._display = _Window()
        self._closed = False
        self._paused = False

    # ---- producer side, called from the VideoToolbox decode thread ----

    def set_paused(self, paused: bool) -> None:
        """Music-safe mode: stop mirroring pixels without tearing the link down."""
        self._paused = paused

    def begin_frame(self) -> bool:
        """Reserve a credit. False means: do not even touch the pixel buffer."""
        if self._paused:
            return False
        with self._lock:
            if self._sock is None or self._credits <= 0:
                self._skipped_nocredit += 1
                return False
            self._credits -= 1
            return True

    def abort_frame(self) -> None:
        with self._lock:
            self._credits = min(CREDITS, self._credits + 1)

    def commit_frame(self, base_address: int, width: int, height: int, bytes_per_row: int) -> None:
        """Copy one locked BGRA pixel buffer into a free slot and announce it."""
        started = time.monotonic_ns()
        with self._lock:
            ring = self._ensure_ring(width, height)
            if ring is None:
                self._credits = min(CREDITS, self._credits + 1)
                return
            slot = self._pick_slot()
            if slot < 0:
                self._credits = min(CREDITS, self._credits + 1)
                return
            self._seq = (self._seq + 1) & 0xFFFFFFFF
            seq = self._seq
            self._inflight[seq] = slot
            generation = self._ring_generation

        destination = ring.slot_address(slot)
        if bytes_per_row == ring.stride:
            ctypes.memmove(destination, base_address, ring.stride * height)
        else:
            self._row_by_row += 1
            row_bytes = min(bytes_per_row, ring.stride)
            for y in range(height):
                ctypes.memmove(
                    destination + y * ring.stride, base_address + y * bytes_per_row, row_bytes
                )

        produced_ns = time.monotonic_ns()
        self._copy.add_ms((produced_ns - started) / 1_000_000.0)
        self._emit(seq, slot, produced_ns, ring, generation)

    def push_bgra(self, bgra: bytes, width: int, height: int) -> None:
        """Fallback for when the decoder patch is unavailable."""
        if not self.begin_frame():
            return
        buffer = (ctypes.c_char * len(bgra)).from_buffer_copy(bgra)
        self.commit_frame(ctypes.addressof(buffer), width, height, width * 4)

    def metrics(self) -> Dict[str, object]:
        with self._lock:
            ring = self._ring
            geometry = f"{ring.width}x{ring.height}" if ring else "-"
            megabytes = (ring.slot_bytes * ring.slots / 1e6) if ring else 0.0
            return {
                "codec": "muvs3",
                "transport": "unix+shm",
                "geometry": geometry,
                "slots": SLOTS,
                "credits": CREDITS,
                "ring_mb": round(megabytes, 1),
                "sent": self._sent,
                "skipped_nocredit": self._skipped_nocredit,
                "row_by_row_copies": self._row_by_row,
                "copy": self._copy.snapshot(),
                "display": self._display.snapshot(),
            }

    # ---- internals ----

    def _ensure_ring(self, width: int, height: int) -> Optional[ShmRing]:
        ring = self._ring
        if ring is not None and (ring.width, ring.height) == (width, height):
            return ring
        if ring is not None:
            ring.close()
        try:
            ring = ShmRing(self._shm_path, width, height, SLOTS)
        except OSError as exc:
            LOG.error("MUVS/3 ring allocation failed: %s", exc)
            self._ring = None
            return None
        self._ring = ring
        self._ring_generation += 1
        self._inflight.clear()
        LOG.info(
            "MUVS/3 ring %dx%d stride=%d ×%d slots (%.1f MB)",
            width,
            height,
            ring.stride,
            SLOTS,
            ring.size / 1e6,
        )
        return ring

    def _pick_slot(self) -> int:
        used = set(self._inflight.values())
        for index in range(SLOTS):
            if index not in used:
                return index
        return -1

    def _emit(self, seq: int, slot: int, produced_ns: int, ring: ShmRing, generation: int) -> None:
        with self._send_lock:
            sock = self._sock
            if sock is None:
                return
            try:
                if generation != self._bound_generation:
                    if not self._send_bind(sock, ring):
                        return
                    self._bound_generation = generation
                sock.sendall(FRAME.pack(MSG_FRAME, seq, slot, produced_ns))
                self._sent += 1
            except (OSError, ValueError) as exc:
                LOG.debug("MUVS/3 send failed: %s", exc)
                self._drop_client(sock)

    def _send_bind(self, sock: socket.socket, ring: ShmRing) -> bool:
        """Hand the ring fd to the UI over SCM_RIGHTS; the path is a fallback."""
        path_bytes = ring.path.encode("utf-8")
        payload = (
            BIND.pack(
                MSG_BIND,
                MAGIC,
                PROTOCOL_VERSION,
                ring.slots,
                ring.stride,
                ring.slot_bytes,
                ring.width,
                ring.height,
                HEADER,
                len(path_bytes),
            )
            + path_bytes
        )
        socket.send_fds(sock, [payload], [ring.fd])
        LOG.info("MUVS/3 bound ring fd=%d %dx%d", ring.fd, ring.width, ring.height)
        return True

    def _drop_client(self, sock: socket.socket) -> None:
        if self._sock is sock:
            self._sock = None
        with self._lock:
            self._credits = 0
            self._inflight.clear()

    # ---- socket lifecycle ----

    async def start(self) -> None:
        self._loop = asyncio.get_running_loop()
        if os.path.exists(self._path):
            with contextlib.suppress(OSError):
                os.unlink(self._path)
        self._server = await asyncio.start_unix_server(self._handle_client, path=self._path)
        os.chmod(self._path, 0o600)
        LOG.info(
            "MUVS/3 socket %s shm %s slots=%d credits=%d",
            self._path,
            self._shm_path,
            SLOTS,
            CREDITS,
        )

    async def stop(self) -> None:
        self._closed = True
        if self._server is not None:
            self._server.close()
            with contextlib.suppress(Exception):
                await self._server.wait_closed()
            self._server = None
        if os.path.exists(self._path):
            with contextlib.suppress(OSError):
                os.unlink(self._path)
        with self._lock:
            if self._ring is not None:
                self._ring.close()
                self._ring = None

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        sock = writer.get_extra_info("socket")
        try:
            head = await reader.readexactly(HELLO.size)
            _, magic, version, _features = HELLO.unpack(head)
            if magic != MAGIC or version != PROTOCOL_VERSION:
                LOG.warning("MUVS/3 reject: magic=%r version=%s", magic, version)
                return

            with self._send_lock:
                self._sock = sock
                self._bound_generation = -1
            with self._lock:
                self._inflight.clear()
                self._credits = CREDITS
            LOG.info("MUVS/3 client attached (v%d)", version)

            while True:
                body = await reader.readexactly(ACK.size)
                kind, seq, displayed_ns = ACK.unpack(body)
                if kind != MSG_ACK:
                    break
                self._on_ack(seq, displayed_ns)
        except (asyncio.IncompleteReadError, ConnectionResetError, asyncio.CancelledError):
            pass
        except Exception as exc:
            LOG.debug("MUVS/3 client error: %s", exc)
        finally:
            with self._send_lock:
                self._drop_client(sock)
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            LOG.info("MUVS/3 client detached")

    def _on_ack(self, seq: int, displayed_ns: int) -> None:
        """Acks are cumulative: everything up to `seq` has been read by the GPU.

        The UI coalesces draws, so a frame can be superseded before it is ever
        displayed. Releasing every slot up to the acknowledged one keeps those
        credits from being lost, which would otherwise starve the pipeline.
        """
        now = time.monotonic_ns()
        with self._lock:
            released = [s for s in self._inflight if s <= seq]
            for done in released:
                self._inflight.pop(done, None)
            self._credits = min(CREDITS, self._credits + max(1, len(released)))
        if displayed_ns:
            self._display.add_ms((now - displayed_ns) / 1_000_000.0)
