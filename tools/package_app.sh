#!/usr/bin/env bash
# Package MirrorUE as a double-clickable .app (+ optional .dmg).
# Requires a prior or inline engine build (bin/MirrorUE + bin/MirrorUEEngine).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="${MIRRORUE_DIST:-$ROOT/dist}"
APP="$DIST/MirrorUE.app"
DMG="$DIST/MirrorUE.dmg"
VERSION="${MIRRORUE_VERSION:-1.1.0}"

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

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MirrorUE</string>
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
  <string>MirrorUE needs camera/screen permission to show your iPhone display via CoreMediaIO.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

cp -f "$ROOT/bin/MirrorUE" "$APP/Contents/MacOS/MirrorUE"
cp -f "$ROOT/bin/MirrorUEEngine" "$APP/Contents/MacOS/MirrorUEEngine"
chmod +x "$APP/Contents/MacOS/MirrorUE" "$APP/Contents/MacOS/MirrorUEEngine"

# Ad-hoc sign so Gatekeeper is less angry on local builds (Developer ID later).
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "==> Creating $DMG"
rm -f "$DMG"
STAGE="$DIST/dmg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"
hdiutil create -volname "MirrorUE" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

ls -lh "$APP/Contents/MacOS/" "$DMG"
echo ""
echo "Open:  open \"$APP\""
echo "DMG:   $DMG"
echo "Tip:   unsigned builds may need right-click → Open the first time."
