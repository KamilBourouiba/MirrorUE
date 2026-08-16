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

# Detect Apple Code Signing Identity
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep -E "Developer ID Application|Apple Development" | head -n 1 | awk -F'"' '{print $2}' || true)
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo "==> Using ad-hoc code signature"
else
  echo "==> Using Apple Developer Identity: $SIGN_IDENTITY"
fi

# Clean Stage in /tmp to prevent Finder/fileprovider xattr corruption
STAGE_DIR="/tmp/mirrorue_pkg_stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/MirrorUE.app/Contents/MacOS"
mkdir -p "$STAGE_DIR/MirrorUE.app/Contents/Resources"

cat > "$STAGE_DIR/MirrorUE.app/Contents/Info.plist" <<EOF
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
  cp -f "$ROOT/bin/MirrorUE" "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUE"
elif [[ -f "$ROOT/bin/MirrorUEApp" ]]; then
  cp -f "$ROOT/bin/MirrorUEApp" "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUE"
fi
cp -f "$ROOT/bin/MirrorUEEngine" "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUEEngine"
chmod +x "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUE" "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUEEngine"

if [[ -f "$ROOT/dist/AppIcon.icns" ]]; then
  cp -f "$ROOT/dist/AppIcon.icns" "$STAGE_DIR/MirrorUE.app/Contents/Resources/AppIcon.icns"
fi

# Sign binaries with Hardened Runtime & Apple Identity
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUEEngine" 2>/dev/null || codesign --force --sign - "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUEEngine" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUE" 2>/dev/null || codesign --force --sign - "$STAGE_DIR/MirrorUE.app/Contents/MacOS/MirrorUE" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ROOT/MirrorUE.entitlements" "$STAGE_DIR/MirrorUE.app" 2>/dev/null || codesign --force --sign - --entitlements "$ROOT/MirrorUE.entitlements" "$STAGE_DIR/MirrorUE.app" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$DIST"
cp -R "$STAGE_DIR/MirrorUE.app" "$APP"

echo "==> Creating $DMG"
rm -f "$DMG"
DMG_STAGE="$DIST/dmg-root"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -sf /Applications "$DMG_STAGE/Applications"

# Set volume icon on DMG if available
if [[ -f "$ROOT/dist/AppIcon.icns" ]]; then
  cp -f "$ROOT/dist/AppIcon.icns" "$DMG_STAGE/.VolumeIcon.icns"
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$DMG_STAGE" 2>/dev/null || true
  fi
fi

hdiutil create -volname "MirrorUE" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
rm -rf "$DMG_STAGE" "$STAGE_DIR"

mkdir -p "$ROOT/docs"
cp -f "$DMG" "$ROOT/docs/MirrorUE.dmg"

ls -lh "$APP/Contents/MacOS/" "$DMG" "$ROOT/docs/MirrorUE.dmg"
echo ""
echo "Signed with: $SIGN_IDENTITY"
echo "Open:        open \"$APP\""
echo "DMG:         $DMG"
echo "Web:         $ROOT/docs/MirrorUE.dmg (Direct Download)"

