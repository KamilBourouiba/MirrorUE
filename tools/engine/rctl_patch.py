#!/usr/bin/env python3
"""Enable Xcode-style RCTL + per-frame RTCP companion on VncStreamServer."""

from __future__ import annotations

import asyncio
import struct
import time
from typing import TYPE_CHECKING, Any, Optional

if TYPE_CHECKING:
    from pymobiledevice3.remote.core_device.vnc_server import VncStreamServer


def apply_rctl(vnc: "VncStreamServer", *, max_bitrate_kbps: int = 60000) -> None:
    """Patch *vnc* in place with Apple mirror rate-control feedback."""
    vnc._rctl_enabled = True  # type: ignore[attr-defined]
    vnc._rctl_maxk = max_bitrate_kbps  # type: ignore[attr-defined]
    vnc._rctl_start_t = 0.0  # type: ignore[attr-defined]
    vnc._rtp_last_ts = 0  # type: ignore[attr-defined]
    vnc._rtp_last_frame_pkts = 0  # type: ignore[attr-defined]
    vnc._rtp_cur_frame_pkts = 0  # type: ignore[attr-defined]
    vnc._rtp_frames_received = 0  # type: ignore[attr-defined]
    vnc._rtp_packets_received = 0  # type: ignore[attr-defined]
    vnc._rtp_prev_transit: Optional[float] = None  # type: ignore[attr-defined]
    vnc._rtp_jitter = 0.0  # type: ignore[attr-defined]
    vnc._active_sock = None  # type: ignore[attr-defined]
    vnc._rctl_task: Optional[asyncio.Task] = None  # type: ignore[attr-defined]

    vnc._build_rctl_packet = _build_rctl_packet.__get__(vnc, type(vnc))  # type: ignore[method-assign]
    vnc._build_rctl_companion_packet = _build_rctl_companion_packet.__get__(vnc, type(vnc))  # type: ignore[method-assign]
    vnc._rctl_feedback_loop = _rctl_feedback_loop.__get__(vnc, type(vnc))  # type: ignore[method-assign]

    orig = vnc._udp_recv_and_pipe

    async def _udp_recv_and_pipe_rctl(transport: Any) -> None:
        vnc._active_sock = transport  # type: ignore[attr-defined]
        if vnc._rctl_task is None:  # type: ignore[attr-defined]
            vnc._rctl_task = asyncio.create_task(vnc._rctl_feedback_loop())  # type: ignore[attr-defined]
        await _udp_recv_with_rctl(vnc, transport, orig)

    vnc._udp_recv_and_pipe = _udp_recv_and_pipe_rctl  # type: ignore[method-assign]


async def _udp_recv_with_rctl(vnc: Any, transport: Any, orig) -> None:
    """Wrap the stock recv loop: track RTP ts + send companion APP on each frame."""
    from pymobiledevice3.remote.core_device import vnc_server as vs

    loop = asyncio.get_running_loop()
    fu_buffer = bytearray()
    current_au: list[bytes] = []
    last_seq: Optional[int] = None
    au_corrupt = False
    au_is_key = False
    nals: list[bytes] = []
    cached_vps: Optional[bytes] = None
    cached_sps: Optional[bytes] = None
    cached_pps: Optional[bytes] = None

    while True:
        try:
            data = await transport.recv()
        except (OSError, asyncio.CancelledError):
            return
        if len(data) < 12:
            continue

        vnc._rtp_packets_received += 1  # type: ignore[attr-defined]
        vnc._rtp_last_ts = int.from_bytes(data[4:8], "big")  # type: ignore[attr-defined]
        vnc._rtp_cur_frame_pkts += 1  # type: ignore[attr-defined]

        pt = data[1] & 0x7F
        if 64 <= pt <= 95:
            continue
        marker = (data[1] >> 7) & 1
        cc = data[0] & 0x0F
        header_len = 12 + cc * 4
        if data[0] & 0x10:
            ext_len = int.from_bytes(data[header_len + 2 : header_len + 4], "big")
            header_len += 4 + ext_len * 4
        payload = data[header_len:]

        seq = int.from_bytes(data[2:4], "big")
        cur_ext = vnc._rtp_highest_seq
        cycles = (cur_ext >> 16) & 0xFFFF
        last_seq16 = cur_ext & 0xFFFF
        if seq < last_seq16 and (last_seq16 - seq) > 0x8000:
            cycles = (cycles + 1) & 0xFFFF
        new_ext = (cycles << 16) | seq
        if cur_ext == 0 or ((new_ext - cur_ext) & 0xFFFFFFFF) < 0x80000000:
            vnc._rtp_highest_seq = new_ext
        if last_seq is not None and seq != ((last_seq + 1) & 0xFFFF):
            fu_buffer.clear()
            au_corrupt = True
        if last_seq is None or ((seq - last_seq) & 0xFFFF) < 0x8000:
            last_seq = seq

        nals.clear()
        vs.depacketize_hevc(payload, fu_buffer, nals)
        for nal in nals:
            if not nal:
                continue
            nt = (nal[0] >> 1) & 0x3F
            if nt == vs._HEVC_NAL_VPS:
                cached_vps = bytes(nal)
            elif nt == vs._HEVC_NAL_SPS:
                cached_sps = bytes(nal)
                vnc._rps_tracker.feed_sps(cached_sps)
            elif nt == vs._HEVC_NAL_PPS:
                cached_pps = bytes(nal)
            elif vs._is_key_nal(nt):
                au_is_key = True
            current_au.append(nal)

        if marker:
            vnc._rtp_frames_received += 1  # type: ignore[attr-defined]
            vnc._rtp_last_frame_pkts = vnc._rtp_cur_frame_pkts  # type: ignore[attr-defined]
            vnc._rtp_cur_frame_pkts = 0  # type: ignore[attr-defined]
            if (
                getattr(vnc, "_rctl_enabled", False)
                and vnc._rtcp_dest is not None
                and vnc._local_ssrc
            ):
                try:
                    pkt = vnc._build_rctl_companion_packet()
                    await transport.sendto(pkt, *vnc._rtcp_dest)
                except OSError:
                    pass

            if current_au and not au_corrupt:
                au_bytes = sum(len(n) for n in current_au)
                vnc._au_byte_window.append((loop.time(), au_bytes))
                if vnc._refresh_pending and au_is_key and vnc._transcoder is not None:
                    try:
                        vnc._transcoder.close()
                    except Exception:
                        pass
                    vnc._transcoder = None
                    vnc._refresh_pending = False
                    vnc._rps_tracker.reset()
                    vnc._idr_observed_at = loop.time()
                    if vnc._keyframe_required:
                        vnc._idr_observed = True
                if (
                    vnc._transcoder is None
                    and au_is_key
                    and cached_vps is not None
                    and cached_sps is not None
                    and cached_pps is not None
                ):
                    try:
                        vnc._transcoder = vnc._transcoder_cls(
                            cached_vps,
                            cached_sps,
                            cached_pps,
                            on_frame=vnc._on_frame_from_worker,
                            on_decode_error=vnc._on_decode_error_from_worker,
                        )
                    except Exception:
                        pass
                if vnc._transcoder is not None and not vnc._refresh_pending:
                    slice_nal = next(
                        (n for n in current_au if vs.is_slice_nal((n[0] >> 1) & 0x3F)),
                        None,
                    )
                    missing: set[int] = set()
                    if slice_nal is not None:
                        missing = vnc._rps_tracker.check_slice(slice_nal)
                    if missing and not au_is_key:
                        vnc._on_decode_error()
                        if vnc._refresh_pending:
                            current_au = []
                            au_is_key = False
                            au_corrupt = False
                            continue
                    annexb = b"".join(b"\x00\x00\x00\x01" + nal for nal in current_au)
                    vnc._transcoder.feed(annexb)
                    vnc._rps_tracker.commit_decoded()
                    if au_is_key:
                        vnc._idr_observed_at = loop.time()
                        if vnc._keyframe_required:
                            vnc._idr_observed = True
            current_au = []
            au_is_key = False
            au_corrupt = False


def _build_rctl_packet(self) -> bytes:
    ts = self._rtp_last_ts & 0xFFFFFFFF
    w2 = ((ts >> 8) & 0xFFFF) << 16
    w3 = self._rtp_last_frame_pkts & 0xFFFFFFFF
    arrival_ms = (ts // 24) & 0xFFFF
    w4 = (arrival_ms << 16) | 0
    w5 = ((self._rtp_packets_received & 0xFFFF) << 16) | 0xEA61
    return struct.pack(
        "!BBHI4sI IIII",
        0x80,
        0xCC,
        7,
        self._local_ssrc & 0xFFFFFFFF,
        b"RCTL",
        0x85000004,
        w2,
        w3,
        w4,
        w5,
    )


def _build_rctl_companion_packet(self) -> bytes:
    return struct.pack(
        "!BBHI I I",
        0x80,
        0xCC,
        3,
        self._local_ssrc & 0xFFFFFFFF,
        5,
        self._rtp_last_ts & 0xFFFFFFFF,
    )


async def _rctl_feedback_loop(self) -> None:
    tick = 0
    while True:
        try:
            await asyncio.sleep(0.025)
        except asyncio.CancelledError:
            return
        transport = getattr(self, "_active_sock", None)
        if (
            not getattr(self, "_rctl_enabled", False)
            or transport is None
            or self._rtcp_dest is None
            or not self._local_ssrc
            or self._rtp_packets_received == 0
        ):
            continue
        if getattr(self, "_rctl_start_t", 0.0) == 0.0:
            self._rctl_start_t = time.monotonic()
        try:
            if tick % 2 == 0:
                await transport.sendto(self._build_rctl_packet(), *self._rtcp_dest)
        except OSError:
            pass
        tick += 1
