#!/usr/bin/env bash
# Build + install MirrorUE.app with entitlements so the FastVLM worker can load conda/MLX dylibs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product MirrorUE
BIN="$(swift build -c release --show-bin-path)/MirrorUE"
mkdir -p dist/MirrorUE.app/Contents/MacOS bin
cp -f "$BIN" bin/MirrorUE
cp -f "$BIN" dist/MirrorUE.app/Contents/MacOS/MirrorUE
chmod +x dist/MirrorUE.app/Contents/MacOS/MirrorUE
# Keep FastVLM agent scripts in sync when packaged.
if [[ -d tools/fastvlm ]]; then
  mkdir -p dist/MirrorUE.app/Contents/Resources/tools/fastvlm/llm
  cp -f tools/fastvlm/*.py dist/MirrorUE.app/Contents/Resources/tools/fastvlm/ 2>/dev/null || true
  cp -f tools/fastvlm/llm/*.py dist/MirrorUE.app/Contents/Resources/tools/fastvlm/llm/ 2>/dev/null || true
fi
xattr -cr dist/MirrorUE.app
codesign --force --sign - --entitlements "$ROOT/MirrorUE.entitlements" \
  dist/MirrorUE.app/Contents/MacOS/MirrorUE
codesign --force --deep --sign - --entitlements "$ROOT/MirrorUE.entitlements" \
  dist/MirrorUE.app || true
echo "OK → dist/MirrorUE.app (FastVLM prefers models/FastVLM-1.5B)"
