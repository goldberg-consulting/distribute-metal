#!/bin/bash

# DistributeMetal Dev Builder
# Build, sign, package DMG, install to /Applications, launch
# Uses swift build (Debug) + Developer ID signing + DMG
# Requires: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

set -e

APP_NAME="DistributeMetal"
VERSION="$(cat "$( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )/VERSION" | tr -d '[:space:]')"
BUNDLE_ID="com.measured.distribute-metal"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

RUN_APP=true; [[ "$1" == "--no-run" ]] && RUN_APP=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_ROOT/apps/DistributeMetal"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     ⚡ DistributeMetal Dev Build v${VERSION}                 ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify Xcode
[[ "$(xcode-select -p)" != *"Xcode.app"* ]] && echo -e "${RED}❌ Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${NC}" && exit 1
echo -e "${GREEN}✓ Xcode${NC}"

# Kill running instances
pkill -9 -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
echo -e "${GREEN}✓ Killed old instances${NC}"

# Reset TCC permissions (signature changes invalidate old grants)
for TCC_SERVICE in LocalNetwork; do
    tccutil reset "$TCC_SERVICE" "$BUNDLE_ID" 2>/dev/null || true
done
echo -e "${GREEN}✓ TCC permissions reset: LocalNetwork${NC}"

# Cleanup
cd "$APP_DIR"
rm -rf .build "$APP_NAME.app"
echo -e "${GREEN}✓ Cleanup${NC}"

# Certificate
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
if [ -n "$DEV_ID" ]; then
    echo -e "${GREEN}✓ Certificate: ${DEV_ID}${NC}"
else
    echo -e "${YELLOW}⚠ No Developer ID found, will use ad-hoc signing${NC}"
fi

# Build
echo -e "${BLUE}🔨 Building (Debug)...${NC}"
swift build -c debug 2>&1 | tail -5
[ ! -f ".build/debug/$APP_NAME" ] && echo -e "${RED}❌ Build failed${NC}" && exit 1
echo -e "${GREEN}✓ Build${NC}"

# Create .app bundle
echo -e "${BLUE}📦 Creating bundle...${NC}"
mkdir -p "$APP_NAME.app/Contents/MacOS" "$APP_NAME.app/Contents/Resources"
ditto --norsrc ".build/debug/$APP_NAME" "$APP_NAME.app/Contents/MacOS/$APP_NAME"

# Copy resources if they exist
[ -f "Resources/AppIcon.icns" ] && ditto --norsrc Resources/AppIcon.icns "$APP_NAME.app/Contents/Resources/AppIcon.icns"

# Generate Info.plist from template
cat > "$APP_NAME.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>DistributeMetal discovers other Macs on your network to form a training cluster.</string>
    <key>NSBonjourServices</key><array><string>_distributemetal._tcp</string></array>
</dict></plist>
EOF
echo -n "APPL????" > "$APP_NAME.app/Contents/PkgInfo"
echo -e "${GREEN}✓ Bundle${NC}"

# Sign
echo -e "${BLUE}🔏 Signing...${NC}"
if [ -n "$DEV_ID" ]; then
    codesign --force --deep --options runtime --sign "$DEV_ID" \
        --entitlements "$PROJECT_ROOT/DistributeMetal.entitlements" \
        "$APP_NAME.app" 2>/dev/null || \
        codesign --force --deep --sign - "$APP_NAME.app" 2>/dev/null || true
    echo -e "${GREEN}✓ Signed (Developer ID)${NC}"
else
    codesign --force --deep --sign - "$APP_NAME.app" 2>/dev/null || true
    echo -e "${YELLOW}✓ Signed (ad-hoc)${NC}"
fi

# Create DMG
echo -e "${BLUE}💿 Creating DMG...${NC}"
mkdir -p "$PROJECT_ROOT/dist"
DMG_PATH="$PROJECT_ROOT/dist/${APP_NAME}-${VERSION}-dev.dmg"
rm -rf "$PROJECT_ROOT/dist/dmg-staging" "$DMG_PATH"
mkdir -p "$PROJECT_ROOT/dist/dmg-staging"
ditto --norsrc "$APP_NAME.app" "$PROJECT_ROOT/dist/dmg-staging/$APP_NAME.app"
ln -s /Applications "$PROJECT_ROOT/dist/dmg-staging/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$PROJECT_ROOT/dist/dmg-staging" -ov -format UDZO "$DMG_PATH" 2>&1 | tail -1
rm -rf "$PROJECT_ROOT/dist/dmg-staging"
echo -e "${GREEN}✓ DMG: ${DMG_PATH} ($(du -h "$DMG_PATH" | cut -f1))${NC}"

# Install to /Applications
echo -e "${BLUE}📲 Installing to /Applications...${NC}"
rm -rf "/Applications/$APP_NAME.app"
ditto --norsrc "$APP_NAME.app" "/Applications/$APP_NAME.app"
echo -e "${GREEN}✓ Installed to /Applications${NC}"

# Cleanup build artifacts
rm -rf "$APP_NAME.app"
echo -e "${GREEN}✓ Cleaned up${NC}"

echo ""
echo -e "${GREEN}🎉 Done! DistributeMetal v${VERSION} installed to /Applications${NC}"

# Launch
if [ "$RUN_APP" = true ]; then
    echo -e "${BLUE}🚀 Launching...${NC}"
    open "/Applications/$APP_NAME.app"
fi
