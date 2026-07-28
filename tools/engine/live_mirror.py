#!/usr/bin/env python3
"""CoreDevice DisplayService → VideoToolbox BGRA → MUVS + HID (MirrorUE engine)."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import uuid
from typing import Any, Optional

from hid_socket import HID_PATH, HidSocketServer
from video_socket import SHM_PATH, VIDEO_PATH, VideoSocketPublisher

LOG = logging.getLogger("mirrorue.live")

BUTTONS = {
    "home": (0x0C, 0x40, 0.05),
    "lock": (0x0C, 0x30, 0.5),
    "volume-up": (0x0C, 0xE9, 0.05),
    "volume-down": (0x0C, 0xEA, 0.05),
    "mute": (0x0C, 0xE2, 0.05),
    "siri": (0x0C, 0xCF, 1.0),
}

USE_NATIVE = os.environ.get("MIRRORUE_NATIVE", "").strip() in ("1", "true", "yes", "on")
VIDEO_TRANSPORT = "unix"


async def open_tunnel(udid: str, connection_type: str):
    import pymobiledevice3.remote.userspace_tunnel as ut

    orig = ut.create_using_usbmux

    async def _create(*args: Any, **kwargs: Any):
        kwargs["connection_type"] = connection_type
        return await orig(*args, **kwargs)

    ut.create_using_usbmux = _create  # type: ignore[assignment]
    tunnel = ut.UserspaceRsdTunnel(serial=udid, autopair=True)
    try:
        rsd = await tunnel.aopen()
    finally:
        ut.create_using_usbmux = orig  # type: ignore[assignment]
    return tunnel, rsd


class MirrorEngine:
    def __init__(self, rsd: Any, http_port: int = 8080) -> None:
        from pymobiledevice3.remote.core_device.vnc_server import VncStreamServer

        self._rsd = rsd
        self._http_port = http_port
        self._vnc = VncStreamServer(
            rsd,
            bind="127.0.0.1",
            port=0,
            display_id=1,
            audio=False,
            decoder="vt",
            allow_rtcp_fb=True,
            ltrp_enabled=False,
        )
        self._video = None
        self._music_safe = False
        self._tasks: list[asyncio.Task] = []
        # Virtual-keyboard bitmap currently held on the phone.
        self._pressed_keys: set[int] = set()
        # key token -> usages synthesised on key-down (so key-up releases the same)
        self._active_typing: dict[str, tuple[int, ...]] = {}
        # After a BrokenPipe, pause HID briefly and reconnect once.
        self._hid_cooldown_until = 0.0
        self._hid_fail_streak = 0
        # Keyboard createService can kill a flaky UHS link — back off separately
        # so touch keeps working while we retry registration later.
        self._kb_fail_streak = 0
        self._kb_retry_after = 0.0
        if USE_NATIVE:
            orig = self._vnc._broadcast_frame
            from vt_direct import apply_direct_frames

            self._video = VideoSocketPublisher()
            direct = os.environ.get("MIRRORUE_VT_DIRECT", "1").strip() not in ("0", "false", "no")
            if not direct or not apply_direct_frames(self._vnc, self._video):
                # Decoder patch declined; fall back to the copied-bytes path.
                def _hook_unix(bgra: bytes) -> None:
                    orig(bgra)
                    if self._video and not self._music_safe:
                        w, h = self._vnc._fb_width, self._vnc._fb_height
                        if w > 0 and h > 0:
                            self._video.push_bgra(bgra, w, h)

                self._vnc._broadcast_frame = _hook_unix  # type: ignore[method-assign]

        if os.environ.get("MIRRORUE_RCTL", "1").strip() not in ("0", "false", "no"):
            from rctl_patch import apply_rctl

            apply_rctl(self._vnc)
            LOG.info("RCTL enabled (Xcode-style rate control)")

    async def _handle_http(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            head = await asyncio.wait_for(reader.readline(), timeout=30)
            if not head:
                return
            parts = head.decode("utf-8", "replace").strip().split()
            if len(parts) < 2:
                return
            method, raw_path = parts[0], parts[1]
            path = raw_path.split("?", 1)[0]
            headers: dict[str, str] = {}
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
                if b":" in line:
                    k, v = line.decode("utf-8", "replace").split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            clen = int(headers.get("content-length", "0"))
            body = b""
            if clen > 0:
                body = await reader.readexactly(clen)

            if path == "/status" and method == "GET":
                payload = {
                    "ok": True,
                    "video": self._vnc._fb_width > 0,
                    "w": self._vnc._fb_width,
                    "h": self._vnc._fb_height,
                    "music_safe": self._music_safe,
                    "frames_emitted": getattr(self._vnc, "_frames_emitted", 0),
                }
                if self._video is not None:
                    payload["native"] = self._video.metrics()
                await self._json(writer, 200, payload)
            elif path == "/touch" and method == "POST":
                d = json.loads(body.decode("utf-8"))
                await self._touch(d.get("type", "contact"), int(d.get("x", 0)), int(d.get("y", 0)))
                await self._json(writer, 200, {"ok": True})
            elif path == "/button" and method == "POST":
                d = json.loads(body.decode("utf-8"))
                await self._button(d.get("name", ""), d.get("state", "press"))
                await self._json(writer, 200, {"ok": True})
            elif path == "/instant" and method == "POST":
                d = json.loads(body.decode("utf-8"))
                hard = bool(d.get("hard", False))
                if hard:
                    if self._vnc._transcoder is not None:
                        with contextlib.suppress(Exception):
                            self._vnc._transcoder.close()
                            self._vnc._transcoder = None
                else:
                    with contextlib.suppress(Exception):
                        await self._vnc._send_rtcp_pli()
                await self._json(writer, 200, {"ok": True, "hard": hard})
            elif path == "/music-safe" and method == "POST":
                d = json.loads(body.decode("utf-8"))
                self._music_safe = bool(d.get("on", False))
                if self._video is not None:
                    self._video.set_paused(self._music_safe)
                await self._json(writer, 200, {"ok": True, "on": self._music_safe})
            elif path == "/key" and method == "POST":
                d = json.loads(body.decode("utf-8"))
                await self._key(
                    bool(d.get("down", True)),
                    int(d.get("usage", 0)),
                    str(d.get("char", "")),
                    int(d.get("mods", 0)),
                )
                await self._json(writer, 200, {"ok": True})
            elif path == "/keyboard-reset" and method == "POST":
                await self._keyboard_reset()
                await self._json(writer, 200, {"ok": True})
            else:
                await self._json(writer, 404, {"error": "not found"})
        except Exception as exc:
            LOG.debug("http error: %s", exc)
        finally:
            with contextlib.suppress(Exception):
                writer.close()
                await writer.wait_closed()

    async def _json(self, writer: asyncio.StreamWriter, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode("utf-8")
        writer.write(
            f"HTTP/1.1 {code} OK\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
        )
        writer.write(body)
        await writer.drain()

    @staticmethod
    def _is_hid_transport_error(exc: BaseException) -> bool:
        if isinstance(
            exc,
            (
                BrokenPipeError,
                ConnectionResetError,
                ConnectionAbortedError,
                asyncio.IncompleteReadError,
                EOFError,
            ),
        ):
            return True
        if isinstance(exc, OSError) and getattr(exc, "errno", None) in (32, 54, 57, 60, 61):
            return True
        msg = str(exc).lower()
        if "connection lost" in msg or "incomplete read" in msg or "broken pipe" in msg:
            return True
        cause = getattr(exc, "__cause__", None) or getattr(exc, "__context__", None)
        if cause is not None and cause is not exc:
            return MirrorEngine._is_hid_transport_error(cause)
        return False

    async def _reset_hid(self, *, reason: str, clear_keyboard_only: bool = False) -> None:
        """Drop dead UniversalHID / Indigo clients so the next call reconnects."""
        import time

        vnc = self._vnc
        self._hid_fail_streak += 1
        delay = min(5.0, 0.25 * (2 ** min(self._hid_fail_streak, 4)))
        self._hid_cooldown_until = time.monotonic() + delay
        LOG.warning(
            "HID transport reset (%s) — cooldown %.1fs (streak=%d)",
            reason,
            delay,
            self._hid_fail_streak,
        )
        vnc._kb_service_id = None
        self._active_typing.clear()
        self._pressed_keys.clear()
        if clear_keyboard_only:
            return
        uhs = getattr(vnc, "_uhs", None)
        indigo = getattr(vnc, "_indigo", None)
        vnc._uhs = None
        vnc._indigo = None
        if uhs is not None:
            with contextlib.suppress(Exception):
                await uhs.close()
        if indigo is not None:
            with contextlib.suppress(Exception):
                await indigo.close()

    async def _hid_ready(self) -> bool:
        import time

        return time.monotonic() >= self._hid_cooldown_until

    async def _run_hid(self, label: str, factory):
        """Run a HID coroutine; on broken pipe, reset once and retry."""
        if not await self._hid_ready():
            return
        try:
            await factory()
            self._hid_fail_streak = 0
            return
        except Exception as exc:
            if not self._is_hid_transport_error(exc):
                raise
            await self._reset_hid(reason=f"{label}: {exc}")
        if not await self._hid_ready():
            return
        try:
            await factory()
            self._hid_fail_streak = 0
        except Exception as exc:
            if self._is_hid_transport_error(exc):
                await self._reset_hid(reason=f"{label} retry: {exc}")
                return
            raise

    async def _ensure_keyboard_service(self) -> None:
        """Register the virtual keyboard once; back off hard on createService failures."""
        import time

        await self._vnc._ensure_hid()
        if self._vnc._kb_service_id is not None:
            return
        now = time.monotonic()
        if now < self._kb_retry_after:
            raise RuntimeError("virtual keyboard temporarily unavailable")

        async with self._vnc._hid_lock:
            if self._vnc._kb_service_id is not None:
                return
            assert self._vnc._uhs is not None
            try:
                sid = await self._vnc._uhs.create_keyboard_service()
                self._vnc._kb_service_id = sid
                self._kb_fail_streak = 0
                LOG.info("virtual keyboard registered (service_id=%s)", sid)
                return
            except Exception as exc:
                create_exc = exc
                self._kb_fail_streak += 1
                self._kb_retry_after = now + min(60.0, 2.0 * (2 ** min(self._kb_fail_streak, 5)))
                LOG.warning(
                    "create_keyboard_service failed (%s) — next try in %.0fs",
                    exc,
                    self._kb_retry_after - now,
                )
        # Release the HID lock before tearing the socket down.
        await self._reset_hid(reason=f"keyboard-create: {create_exc}")
        raise create_exc

    async def _warm_hid(self) -> None:
        """Open UniversalHID + keyboard once the media stream is up (auth gate)."""
        try:
            await self._vnc._ensure_hid()
            LOG.info("UniversalHID connected")
        except Exception as exc:
            LOG.warning("UniversalHID warm-up failed: %s", exc)
            return
        try:
            await self._ensure_keyboard_service()
        except Exception as exc:
            LOG.warning(
                "keyboard warm-up deferred: %s (touch still available; will retry on key)",
                exc,
            )

    async def _touch(self, op: str, x: int, y: int) -> None:
        from pymobiledevice3.remote.core_device.hid_service import (
            DIGITIZER_SURFACE_MAIN_TOUCHSCREEN,
            TOUCHSCREEN_STATE_CONTACT,
            TOUCHSCREEN_STATE_RELEASE,
        )

        async def once() -> None:
            await self._vnc._ensure_hid()
            uhs = self._vnc._uhs
            assert uhs is not None
            st = TOUCHSCREEN_STATE_CONTACT if op == "contact" else TOUCHSCREEN_STATE_RELEASE
            # Serialize on the same lock as createService / keyboard reports.
            async with self._vnc._hid_lock:
                await uhs.send_touchscreen(st, x, y, service_id=DIGITIZER_SURFACE_MAIN_TOUCHSCREEN)

        await self._run_hid(f"touch:{op}", once)

    async def _music_handler(self, on: bool) -> None:
        self._music_safe = on
        if self._video is not None:
            self._video.set_paused(on)

    async def _instant_handler(self, hard: bool) -> None:
        if hard:
            if self._vnc._transcoder is not None:
                with contextlib.suppress(Exception):
                    self._vnc._transcoder.close()
                    self._vnc._transcoder = None
        else:
            with contextlib.suppress(Exception):
                await self._vnc._send_rtcp_pli()

    def _write_rsd_meta(self, transport: Any) -> None:
        try:
            host = self._rsd.service.address[0]
            ports = {}
            for name in (
                "com.apple.coredevice.displayservice",
                "com.apple.coredevice.hid.universalhidservice",
                "com.apple.coredevice.hid.indigo",
            ):
                with contextlib.suppress(Exception):
                    ports[name] = self._rsd.get_service_port(name)
            meta = {
                "host": host,
                "ports": ports,
                "hid_socket": HID_PATH,
                "video_socket": VIDEO_PATH,
                "video_shm": SHM_PATH,
                "video_transport": VIDEO_TRANSPORT,
                "fb_path": os.environ.get("MIRRORUE_FB_PATH", "/tmp/mirrorue_zero.fb"),
                "fb_meta": os.environ.get("MIRRORUE_SHM_META", "/tmp/mirrorue_zero_shm.json"),
            }
            with open("/tmp/mirrorue_rsd.json", "w", encoding="utf-8") as f:
                json.dump(meta, f)
        except Exception as exc:
            LOG.debug("rsd meta write failed: %s", exc)

    async def _button(self, name: str, state: str) -> None:
        from pymobiledevice3.remote.core_device.hid_service import HID_BUTTON_STATE_DOWN, HID_BUTTON_STATE_UP

        spec = BUTTONS.get(name)
        if not spec:
            return
        page, code, _ = spec
        st = HID_BUTTON_STATE_DOWN if state == "press" else HID_BUTTON_STATE_UP

        async def once() -> None:
            await self._vnc._ensure_indigo()
            assert self._vnc._indigo is not None
            await self._vnc._indigo.send_button(page, code, st)

        await self._run_hid(f"button:{name}", once)

    async def _key(self, down: bool, usage: int, char: str, mods: int) -> None:
        """Inject a key onto the phone's virtual HID keyboard.

        Prefer an explicit HID ``usage`` from the Mac app (physical key position
        or phone-layout chord). Fall back to ``char`` → US HID only when usage
        is 0 — otherwise an AZERTY iPhone remaps US logical ``a`` (0x04) to ``q``.
        """
        from pymobiledevice3.remote.core_device.hid_service import (
            ASCII_TO_HID,
            KEY_LEFT_ALT,
            KEY_LEFT_CTRL,
            KEY_LEFT_GUI,
            KEY_LEFT_SHIFT,
        )

        token = f"u:{usage}" if usage else (char if char else "u:0")
        usages: tuple[int, ...] = ()

        if usage:
            held = [usage]
            if mods & 0x01:
                held.insert(0, KEY_LEFT_SHIFT)
            if mods & 0x02:
                held.insert(0, KEY_LEFT_CTRL)
            if mods & 0x04:
                held.insert(0, KEY_LEFT_ALT)
            if mods & 0x08:
                held.insert(0, KEY_LEFT_GUI)
            usages = tuple(held)
        elif char:
            try:
                from keyboard_map import fold_glyph, glyph_to_hid
            except ImportError:
                fold_glyph = None  # type: ignore[assignment]
                glyph_to_hid = None  # type: ignore[assignment]
            mapping = None
            if glyph_to_hid is not None:
                mapping = glyph_to_hid(char, ASCII_TO_HID)
            if mapping is None:
                mapping = (
                    ASCII_TO_HID.get(char)
                    or ASCII_TO_HID.get(char.lower())
                    or ASCII_TO_HID.get(char.upper())
                )
            if mapping is not None:
                hid_usage, needs_shift = mapping
                held = [hid_usage]
                base = char[:1]
                if fold_glyph is not None:
                    folded = fold_glyph(char)
                    base = (folded or char)[:1]
                want_shift = bool(needs_shift) or base.isupper()
                if want_shift:
                    held.insert(0, KEY_LEFT_SHIFT)
                if mods & 0x02:
                    held.insert(0, KEY_LEFT_CTRL)
                if mods & 0x08:
                    held.insert(0, KEY_LEFT_GUI)
                usages = tuple(held)
        if not usages:
            return

        if down:
            self._active_typing[token] = usages
        else:
            self._active_typing.pop(token, None)

        held_now: set[int] = set()
        for group in self._active_typing.values():
            held_now.update(group)
        self._pressed_keys = held_now

        async def once() -> None:
            await self._ensure_keyboard_service()
            uhs = self._vnc._uhs
            sid = self._vnc._kb_service_id
            assert uhs is not None and sid is not None
            async with self._vnc._hid_lock:
                await uhs.send_keyboard(sid, self._pressed_keys)

        try:
            await self._run_hid("key", once)
        except RuntimeError:
            return

    async def _keyboard_reset(self) -> None:
        """Release every virtual key — call when focusing UI / text fields."""
        self._active_typing.clear()
        self._pressed_keys.clear()

        async def once() -> None:
            await self._ensure_keyboard_service()
            uhs = self._vnc._uhs
            sid = self._vnc._kb_service_id
            assert uhs is not None and sid is not None
            async with self._vnc._hid_lock:
                await uhs.send_keyboard(sid, ())

        try:
            await self._run_hid("keyboard-reset", once)
        except RuntimeError:
            return


async def _mirror_engine_run(self) -> None:
    from pymobiledevice3.remote.core_device.display_service import DisplayService
    from pymobiledevice3.remote.core_device.screen_stream import open_media_receiver

    svc = DisplayService(self._rsd)
    await svc.connect()
    transport, receiver_ip = open_media_receiver(svc, (8 * 1024 * 1024, 4 * 1024 * 1024))
    sid = uuid.uuid4()
    answer = await svc.start_video_stream(
        receiver_ip=receiver_ip,
        receiver_port=transport.port,
        sender_ip=self._vnc._sender_ip,
        display_id=1,
        client_session_id=sid,
        allow_rtcp_fb=True,
        ltrp_enabled=False,
    )
    cfg = answer["connection"].get("streamConfig", {})
    source_port = int(cfg.get("SourcePort", 0))
    self._vnc._local_ssrc = int(cfg.get("RemoteSSRC", 0))
    self._vnc._remote_ssrc = int(cfg.get("LocalSSRC", 0))
    self._vnc._rtcp_dest = (self._vnc._sender_ip, source_port) if source_port else None
    self._vnc._active_transport = transport
    loop = asyncio.get_running_loop()
    self._vnc._loop = loop
    LOG.info(
        "live video up: %dx%d HEVC → VT BGRA",
        int(cfg.get("CustomWidth", 0)),
        int(cfg.get("CustomHeight", 0)),
    )
    self._tasks = [
        asyncio.create_task(self._vnc._udp_recv_and_pipe(transport)),
        asyncio.create_task(self._vnc._decoder_refresh_loop()),
        asyncio.create_task(self._vnc._rtcp_send_loop(transport)),
    ]
    self._write_rsd_meta(transport)
    hid = HidSocketServer()
    hid.bind(
        touch=self._touch,
        button=self._button,
        instant=self._instant_handler,
        music=self._music_handler,
        key=self._key,
        reset=self._keyboard_reset,
    )
    await hid.start()
    LOG.info("HID unix socket %s", HID_PATH)
    await self._warm_hid()
    if self._video is not None:
        await self._video.start()
    server = await asyncio.start_server(self._handle_http, "127.0.0.1", self._http_port)
    LOG.info("control http://127.0.0.1:%s/", self._http_port)
    try:
        await server.serve_forever()
    finally:
        server.close()
        await server.wait_closed()
        await hid.stop()
        if self._video is not None:
            await self._video.stop()
        for t in self._tasks:
            t.cancel()
        with contextlib.suppress(Exception):
            await asyncio.gather(*self._tasks, return_exceptions=True)
        await self._vnc._stop_hid()
        with contextlib.suppress(Exception):
            transport.close()


MirrorEngine.run = _mirror_engine_run  # type: ignore[method-assign]
