#!/usr/bin/env python3
"""Route VideoToolbox output straight into the MUVS/3 ring.

`HevcToBgraTranscoder._emit` normally turns each decoded frame into a Python
`bytes`, which on a 1216x2656 stream costs three 12.9 MB copies plus a strided
alpha fill — measured at ~11.9 ms per frame, all of it wasted here: the Metal
shader already forces alpha to 1.0, and the UI reads pixels from shared memory
rather than from `bytes`.

This patch replaces that with a single `memmove` from the locked pixel buffer
into a ring slot (~0.7 ms), and skips the copy entirely when the UI has no
credit outstanding. It is deliberately narrow and reversible; if anything about
the decoder does not look as expected the original path is left in place.
"""

from __future__ import annotations

import logging
from typing import Any

LOG = logging.getLogger("mirrorue.video")


def apply_direct_frames(vnc: Any, publisher: Any) -> bool:
    """Patch the decoder in place. Returns False if the normal path still runs."""
    try:
        from pymobiledevice3.remote.core_device import vt_jpeg
    except ImportError as exc:
        LOG.warning("MUVS/3 direct decode unavailable: %s", exc)
        return False

    transcoder_class = getattr(vt_jpeg, "HevcToBgraTranscoder", None)
    core_video = getattr(vt_jpeg, "cv", None)
    read_only = getattr(vt_jpeg, "kCVPixelBufferLock_ReadOnly", None)
    if transcoder_class is None or core_video is None or read_only is None:
        LOG.warning("MUVS/3 direct decode: unexpected decoder layout, keeping copy path")
        return False
    if getattr(transcoder_class, "_mirrorue_direct", False):
        return True

    lock_base = core_video.CVPixelBufferLockBaseAddress
    unlock_base = core_video.CVPixelBufferUnlockBaseAddress
    get_width = core_video.CVPixelBufferGetWidth
    get_height = core_video.CVPixelBufferGetHeight
    get_stride = core_video.CVPixelBufferGetBytesPerRow
    get_base = core_video.CVPixelBufferGetBaseAddress

    def _emit(self: Any, image_buf: int) -> None:
        if not publisher.begin_frame():
            return
        if lock_base(image_buf, read_only) != 0:
            publisher.abort_frame()
            return
        try:
            width = int(get_width(image_buf))
            height = int(get_height(image_buf))
            stride = int(get_stride(image_buf))
            base = get_base(image_buf)
            if not base or width <= 0 or height <= 0:
                publisher.abort_frame()
                return
            publisher.commit_frame(base, width, height, stride)
        except Exception as exc:
            publisher.abort_frame()
            LOG.debug("MUVS/3 direct emit failed: %s", exc)
            return
        finally:
            unlock_base(image_buf, read_only)

        _note_frame(vnc, width, height)

    transcoder_class._emit = _emit
    transcoder_class._mirrorue_direct = True
    LOG.info("MUVS/3 direct decode enabled (CVPixelBuffer → shared memory, single copy)")
    return True


def _note_frame(vnc: Any, width: int, height: int) -> None:
    """Keep the VNC server's readiness state accurate without producing bytes."""
    try:
        vnc._frames_emitted += 1
        if vnc._ready.is_set():
            return
        vnc._fb_width = width
        vnc._fb_height = height
        loop = vnc._loop
        if loop is not None and not loop.is_closed():
            # _ready is an asyncio.Event, so it has to be set on the loop thread.
            loop.call_soon_threadsafe(vnc._ready.set)
    except Exception:
        pass
