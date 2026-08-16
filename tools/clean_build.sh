#!/usr/bin/env bash
# Perform a clean build, terminate existing app processes, package dist/MirrorUE.app, and open a new instance.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Terminating running MirrorUE processes"
killall MirrorUE 2>/dev/null || true

echo "==> Cleaning Swift Package Manager cache"
swift package clean 2>/dev/null || true
rm -rf "$ROOT/bin" "$ROOT/dist" "$ROOT/.build/pyinstaller"

echo "==> Building and packaging (Clean)"
MIRRORUE_CLEAN=1 ./tools/package_app.sh "$@"

echo "==> Launching fresh MirrorUE instance"
open -n "$ROOT/dist/MirrorUE.app"
