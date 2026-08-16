#!/usr/bin/env bash
# Build Swift MirrorUE + freeze CoreDevice engine (Mach-O, no user Python).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-python3}"

echo "==> swift build -c release --product MirrorUE"
swift build -c release --product MirrorUE
BIN_DIR="$ROOT/.build/arm64-apple-macosx/release"
if [[ ! -d "$BIN_DIR" ]]; then
  BIN_DIR="$(swift build -c release --show-bin-path 2>/dev/null | tail -n 1 | tr -d '\r\n')"
fi
BIN="$BIN_DIR/MirrorUE"
if [[ ! -f "$BIN" ]]; then
  BIN="$BIN_DIR/MirrorUEApp"
fi
if [[ ! -f "$BIN" ]]; then
  BIN="$(find "$ROOT/.build" \( -name "MirrorUE" -o -name "MirrorUEApp" \) -type f 2>/dev/null | head -n 1)"
fi
if [[ -z "$BIN" || ! -f "$BIN" ]]; then
  echo "Error: MirrorUE binary build failed or not found." >&2
  exit 1
fi
mkdir -p bin
cp -f "$BIN" bin/MirrorUE
chmod +x bin/MirrorUE

echo "==> PyInstaller MirrorUEEngine"
mkdir -p "$ROOT/.build/pyinstaller/MirrorUEEngine"
"$PY" -m PyInstaller \
  --noconfirm --clean --onefile \
  --name MirrorUEEngine \
  --distpath "$ROOT/bin" \
  --workpath "$ROOT/.build/pyinstaller" \
  --specpath "$ROOT/.build/pyinstaller" \
  --paths "$ROOT/tools/engine" \
  --hidden-import=live_mirror \
  --hidden-import=vt_direct \
  --hidden-import=rctl_patch \
  --hidden-import=video_socket \
  --hidden-import=muvs_shm \
  --hidden-import=hid_socket \
  --hidden-import=keyboard_map \
  --hidden-import=pymobiledevice3.remote.userspace_tunnel \
  --hidden-import=pymobiledevice3.remote.core_device.vnc_server \
  --hidden-import=pymobiledevice3.remote.core_device.vt_jpeg \
  --hidden-import=pymobiledevice3.remote.core_device.display_service \
  --hidden-import=pymobiledevice3.remote.core_device.hid_service \
  --hidden-import=pymobiledevice3.remote.core_device.screen_stream \
  --hidden-import=IPython \
  --exclude-module=matplotlib \
  --exclude-module=jupyter \
  --exclude-module=notebook \
  --exclude-module=pandas \
  --exclude-module=numba \
  --exclude-module=PyQt6 \
  --exclude-module=cv2 \
  --exclude-module=numpy \
  --collect-submodules=pymobiledevice3 \
  --collect-submodules=pmd_pytcp \
  --collect-submodules=construct \
  --collect-data=pymobiledevice3 \
  "$ROOT/tools/mirrorue_engine.py"

chmod +x "$ROOT/bin/MirrorUEEngine"
ls -lh bin/MirrorUE bin/MirrorUEEngine
echo "Run: ./mirroring"
