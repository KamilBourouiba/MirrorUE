#!/usr/bin/env python3
"""Shared-memory frame ring for the MUVS/3 transport.

Slots hold full-resolution BGRA exactly as VideoToolbox produced it. The UI maps
this file and builds Metal textures straight over the slots, so these bytes are
the ones the GPU samples — nothing is uploaded and nothing is converted.

Row stride is padded to 256 bytes because Metal requires linear textures to have
an aligned `bytesPerRow`, and slots are page aligned because
`makeBuffer(bytesNoCopy:)` requires a page-aligned address and length.
"""

from __future__ import annotations

import ctypes
import mmap
import os
import struct

MAGIC = b"MUV3"
PAGE = 4096
HEADER = PAGE
ROW_ALIGN = 256

HEADER_LAYOUT = struct.Struct("<4sIIIHH")


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) // boundary * boundary


class ShmRing:
    """`slots` page-aligned BGRA frames in one mmap'd file shared by fd."""

    def __init__(self, path: str, width: int, height: int, slots: int = 4) -> None:
        self.path = path
        self.width = width
        self.height = height
        self.slots = slots
        self.stride = align(width * 4, ROW_ALIGN)
        self.slot_bytes = align(self.stride * height, PAGE)
        self.size = HEADER + self.slot_bytes * slots

        self.fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        os.ftruncate(self.fd, self.size)
        self.mm = mmap.mmap(self.fd, self.size)
        HEADER_LAYOUT.pack_into(
            self.mm, 0, MAGIC, slots, self.stride, self.slot_bytes, width, height
        )
        # Keeping this alive is what keeps `base_address` valid.
        self._anchor = ctypes.c_char.from_buffer(self.mm)
        self.base_address = ctypes.addressof(self._anchor)

    def slot_address(self, index: int) -> int:
        return self.base_address + HEADER + index * self.slot_bytes

    def close(self) -> None:
        self._anchor = None
        try:
            self.mm.close()
        except (BufferError, ValueError):
            pass  # a consumer still holds a view; the OS reclaims it on exit
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.unlink(self.path)
        except OSError:
            pass
