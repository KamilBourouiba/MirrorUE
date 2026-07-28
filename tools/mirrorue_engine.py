#!/usr/bin/env python3
"""MirrorUEEngine — CoreDevice tunnel + VideoToolbox BGRA + HID (frozen Mach-O)."""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parent / "engine"
sys.path.insert(0, str(ENGINE_DIR))

LOG = logging.getLogger("mirrorue.engine")


def main() -> int:
    ap = argparse.ArgumentParser(prog="MirrorUEEngine")
    ap.add_argument("--udid", required=True)
    ap.add_argument("--transport", choices=("usb", "wifi"), default="usb")
    ap.add_argument("--http-port", type=int, default=8080)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    os.environ["MIRRORUE_NATIVE"] = "1"
    os.environ.setdefault("MIRRORUE_PUSH", "rgba")
    conn = "USB" if args.transport == "usb" else "Network"

    async def run() -> None:
        from live_mirror import MirrorEngine, open_tunnel

        tunnel, rsd = await open_tunnel(args.udid, conn)
        LOG.info("Tunnel up (%s)", conn)
        try:
            eng = MirrorEngine(rsd, http_port=args.http_port)
            await eng.run()
        finally:
            await tunnel.aclose()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
