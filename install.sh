#!/usr/bin/env bash
# ==============================================================================
#  MirrorUE — 1-Click macOS App Installer
#  Builds, packages, signs, and installs MirrorUE.app to /Applications
# ==============================================================================
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RESET="\033[0m"

echo -e "${BLUE}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║             📱 MirrorUE macOS Installer           ║"
echo "  ║     Ultra-Low-Latency 120 FPS iPhone Mirroring    ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${RESET}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 1. Check prerequisites
echo -e "${CYAN}==> Checking prerequisites...${RESET}"
if ! command -v swift &>/dev/null; then
  echo -e "${YELLOW}Error: Xcode Command Line Tools or Swift not found.${RESET}"
  echo "Run: xcode-select --install"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo -e "${YELLOW}Error: python3 not found.${RESET}"
  exit 1
fi

echo -e "${GREEN}✓ Swift & Python3 ready${RESET}"

# 2. Build binaries (UI + Engine)
echo -e "\n${CYAN}==> Building Swift release binary (Apple Silicon / Metal optimized)...${RESET}"
swift build -c release --product MirrorUE
BIN_PATH="$(swift build -c release --show-bin-path)/MirrorUE"
mkdir -p bin
cp -f "$BIN_PATH" bin/MirrorUE

if [[ ! -f "bin/MirrorUEEngine" ]]; then
  echo -e "\n${CYAN}==> Freezing CoreDevice engine binary...${RESET}"
  ./tools/build_engine.sh
fi
echo -e "${GREEN}✓ Binaries ready: bin/MirrorUE & bin/MirrorUEEngine${RESET}"

# 3. Create .app Bundle structure
echo -e "\n${CYAN}==> Creating macOS App Bundle...${RESET}"
APP_BUNDLE="dist/MirrorUE.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy UI & Engine executables
cp -f "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/MirrorUE"
chmod +x "$APP_BUNDLE/Contents/MacOS/MirrorUE"

if [[ -f "bin/MirrorUEEngine" ]]; then
  cp -f "bin/MirrorUEEngine" "$APP_BUNDLE/Contents/MacOS/MirrorUEEngine"
  chmod +x "$APP_BUNDLE/Contents/MacOS/MirrorUEEngine"
fi

# Copy AppIcon if available
if [[ -f "dist/AppIcon.icns" ]]; then
  cp -f "dist/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Generate Info.plist
cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
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
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>1.2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>MirrorUE needs camera permission to capture your iPhone screen at 120 FPS via CoreMediaIO.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# 4. Code Sign App Bundle
echo -e "\n${CYAN}==> Signing App Bundle with entitlements...${RESET}"
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - --entitlements "$ROOT/MirrorUE.entitlements" "$APP_BUNDLE"
echo -e "${GREEN}✓ App signed successfully${RESET}"

# 5. Install to Applications
echo -e "\n${CYAN}==> Installing to Applications...${RESET}"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/MirrorUE.app"
cp -R "$APP_BUNDLE" "$HOME/Applications/"
echo -e "${GREEN}✓ Installed to $HOME/Applications/MirrorUE.app${RESET}"

if cp -R "$APP_BUNDLE" "/Applications/" 2>/dev/null; then
  echo -e "${GREEN}✓ Also installed to system /Applications/MirrorUE.app${RESET}"
fi

# 6. Create CLI shortcut
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/MirrorUE" "$HOME/.local/bin/mirrorue"
if [[ -w "/usr/local/bin" ]]; then
  ln -sf "$ROOT/bin/MirrorUE" "/usr/local/bin/mirrorue" 2>/dev/null || true
fi
echo -e "${GREEN}✓ CLI shortcut created: mirrorue${RESET}"

echo -e "\n${GREEN}${BOLD}═══════════════════════════════════════════════════"
echo "  🎉 Installation Complete!"
echo "═══════════════════════════════════════════════════${RESET}"
echo -e "You can launch MirrorUE by:"
echo -e "  1. Opening ${BOLD}MirrorUE${RESET} from ${BOLD}Spotlight${RESET} (⌘ + Space) or ${BOLD}Applications${RESET}"
echo -e "  2. Running ${CYAN}open ~/Applications/MirrorUE.app${RESET}"
echo -e "  3. Running ${CYAN}./bin/MirrorUE${RESET} or ${CYAN}mirrorue${RESET} in Terminal"
echo ""
