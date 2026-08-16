#!/usr/bin/env bash
# Package MirrorUE as a double-clickable .app (+ optional .dmg).
# Requires a prior or inline engine build (bin/MirrorUE + bin/MirrorUEEngine).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/MirrorUE.app"
DMG="$DIST/MirrorUE.dmg"
VERSION="${MIRRORUE_VERSION:-1.1.0}"

CLEAN_BUILD="${MIRRORUE_CLEAN:-0}"
for arg in "$@"; do
  if [[ "$arg" == "--clean" ]]; then
    CLEAN_BUILD=1
  fi
done

if [[ "$CLEAN_BUILD" == "1" ]]; then
  echo "==> Cleaning build caches and killing running instances"
  killall MirrorUE 2>/dev/null || true
  swift package clean 2>/dev/null || true
  rm -rf "$ROOT/bin" "$ROOT/dist" "$ROOT/.build/pyinstaller"
  rm -rf "$HOME/Library/Application Support/pyinstaller"
fi

# Always terminate old instances of MirrorUE before building so `open` doesn't focus an old process
killall MirrorUE 2>/dev/null || true

if [[ "${MIRRORUE_SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> Building binaries"
  ./tools/build_engine.sh
else
  echo "==> Skipping build (MIRRORUE_SKIP_BUILD=1)"
  test -x "$ROOT/bin/MirrorUE" && test -x "$ROOT/bin/MirrorUEEngine"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MirrorUE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>app.mirrorue.MirrorUE</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>MirrorUE</string>
  <key>CFBundleDisplayName</key><string>MirrorUE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>MirrorUE needs camera permission to capture your iPhone screen at 120 FPS via CoreMediaIO.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

if [[ -f "$ROOT/bin/MirrorUE" ]]; then
  cp -f "$ROOT/bin/MirrorUE" "$APP/Contents/MacOS/MirrorUE"
elif [[ -f "$ROOT/bin/MirrorUEApp" ]]; then
  cp -f "$ROOT/bin/MirrorUEApp" "$APP/Contents/MacOS/MirrorUE"
fi
cp -f "$ROOT/bin/MirrorUEEngine" "$APP/Contents/MacOS/MirrorUEEngine"
chmod +x "$APP/Contents/MacOS/MirrorUE" "$APP/Contents/MacOS/MirrorUEEngine"

if [[ -f "$ROOT/dist/AppIcon.icns" ]]; then
  cp -f "$ROOT/dist/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Clean and Sign bundle with entitlements
xattr -cr "$APP" 2>/dev/null || true
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --entitlements "$ROOT/MirrorUE.entitlements" "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "==> Creating $DMG"
rm -f "$DMG"
STAGE="$DIST/dmg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"

# Set volume icon on DMG if available
if [[ -f "$ROOT/dist/AppIcon.icns" ]]; then
  cp -f "$ROOT/dist/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$STAGE" 2>/dev/null || true
  fi
fi

hdiutil create -volname "MirrorUE" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

mkdir -p "$ROOT/docs"
cp -f "$DMG" "$ROOT/docs/MirrorUE.dmg"

ls -lh "$APP/Contents/MacOS/" "$DMG" "$ROOT/docs/MirrorUE.dmg"
echo ""
echo "Open:  open \"$APP\""
echo "DMG:   $DMG"
echo "Web:   $ROOT/docs/MirrorUE.dmg (Direct Download)"
echo "Tip:   unsigned builds may need right-click → Open the first time."
