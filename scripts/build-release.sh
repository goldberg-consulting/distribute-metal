#!/bin/bash

# DistributeMetal Release Builder
# Creates a signed and notarized DMG for distribution
# Requires: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

set -e

APP_NAME="DistributeMetal"
BUNDLE_ID="one.measured.distribute-metal"
VERSION="$(cat "$( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )/VERSION" | tr -d '[:space:]')"
DMG_NAME="${APP_NAME}-${VERSION}"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_ROOT/apps/DistributeMetal"

[ -f "$PROJECT_ROOT/.env" ] && source "$PROJECT_ROOT/.env" && echo -e "${BLUE}📋 Loaded .env${NC}"

NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
RELEASE_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$APP_NAME.app"

SKIP_NOTARIZE=false
for arg in "$@"; do [[ "$arg" == "--skip-notarize" ]] && SKIP_NOTARIZE=true; done

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     ⚡ DistributeMetal Release Builder v${VERSION}          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify Xcode
[[ "$(xcode-select -p)" != *"Xcode.app"* ]] && echo -e "${RED}❌ Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${NC}" && exit 1
echo -e "${GREEN}✓ Xcode${NC}"

# Cleanup
pkill -9 -x "$APP_NAME" 2>/dev/null || true
cd "$APP_DIR"
rm -rf .build "$APP_BUNDLE"
echo -e "${GREEN}✓ Cleanup${NC}"

# Certificate (required for release)
DEV_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
[ -z "$DEV_ID" ] && echo -e "${RED}❌ No Developer ID Application certificate found${NC}" && exit 1
echo -e "${GREEN}✓ Certificate: ${DEV_ID}${NC}"

# Check notarization credentials
NOTARY_PROFILE_NAME="${NOTARY_PROFILE:-AC_PASSWORD}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE_NAME" &>/dev/null; then
    echo -e "${GREEN}✓ Found notarization profile: ${NOTARY_PROFILE_NAME}${NC}"
elif [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ] && [ -n "$APP_SPECIFIC_PASSWORD" ]; then
    echo -e "${GREEN}✓ Using notarization credentials from .env${NC}"
    USE_ENV_CREDENTIALS=true
else
    echo -e "${YELLOW}⚠️  Notarization credentials not configured${NC}"
    echo ""
    echo "To set up notarization, either:"
    echo ""
    echo "1. Create a .env file with:"
    echo "   APPLE_ID=\"your-apple-id@email.com\""
    echo "   TEAM_ID=\"YOUR_TEAM_ID\""
    echo "   APP_SPECIFIC_PASSWORD=\"your-app-specific-password\""
    echo ""
    echo "2. Or store in keychain:"
    echo "   xcrun notarytool store-credentials \"notarytool-profile\" \\"
    echo "     --apple-id \"your-apple-id@email.com\" \\"
    echo "     --team-id \"YOUR_TEAM_ID\" \\"
    echo "     --password \"your-app-specific-password\""
    echo ""
    read -p "Continue without notarization? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SKIP_NOTARIZE=true
fi

# Step 1: Clean build
echo -e "\n${BLUE}[1/6] Building release...${NC}"
mkdir -p "$RELEASE_DIR"
swift build -c release -j 1
[ ! -f ".build/release/$APP_NAME" ] && echo -e "${RED}❌ Build failed${NC}" && exit 1
echo -e "${GREEN}✓ Build${NC}"

# Step 2: Create app bundle
echo -e "\n${BLUE}[2/6] Creating bundle...${NC}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
ditto --norsrc ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
[ -f "Resources/AppIcon.icns" ] && ditto --norsrc Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
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
    <key>NSLocalNetworkUsageDescription</key><string>measured.one.distribute-metal discovers other Macs on your network to form a training cluster.</string>
    <key>NSBonjourServices</key><array><string>_distributemetal._tcp</string></array>
</dict></plist>
EOF
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Bundle Python agent source
echo -e "${BLUE}📦 Bundling agent...${NC}"
AGENT_SRC="$PROJECT_ROOT/agent"
AGENT_DEST="$APP_BUNDLE/Contents/Resources/agent"
mkdir -p "$AGENT_DEST"
cp -R "$AGENT_SRC/src" "$AGENT_DEST/src"
cp "$AGENT_SRC/pyproject.toml" "$AGENT_DEST/"
cp "$AGENT_SRC/uv.lock" "$AGENT_DEST/"
echo -e "${GREEN}✓ Agent bundled${NC}"

# Remove xattrs before signing
echo -e "${BLUE}🧹 Removing xattrs from bundle...${NC}"
find "$APP_BUNDLE" -type f -exec xattr -c {} \; 2>/dev/null || true
find "$APP_BUNDLE" -type d -exec xattr -c {} \; 2>/dev/null || true
xattr -rc "$APP_BUNDLE" 2>/dev/null || true
echo -e "${GREEN}✓ Bundle${NC}"

# Step 3: Sign
echo -e "\n${BLUE}[3/6] Signing with Developer ID...${NC}"
codesign --force --deep --options runtime --sign "$DEV_ID" \
    --timestamp --entitlements "$PROJECT_ROOT/DistributeMetal.entitlements" \
    "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
echo -e "${GREEN}✓ Signed${NC}"

# Step 4: Create DMG
echo -e "\n${BLUE}[4/6] Creating DMG...${NC}"
DMG_FINAL="${RELEASE_DIR}/${DMG_NAME}.dmg"
rm -rf "${RELEASE_DIR}/dmg-staging" "$DMG_FINAL"
mkdir -p "${RELEASE_DIR}/dmg-staging"
ditto --norsrc "$APP_BUNDLE" "${RELEASE_DIR}/dmg-staging/$APP_BUNDLE"
ln -s /Applications "${RELEASE_DIR}/dmg-staging/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "${RELEASE_DIR}/dmg-staging" -ov -format UDZO "$DMG_FINAL"
rm -rf "${RELEASE_DIR}/dmg-staging"
codesign --force --sign "$DEV_ID" --timestamp "$DMG_FINAL"
echo -e "${GREEN}✓ DMG${NC}"

# Step 5: Notarize
if [ "$SKIP_NOTARIZE" = true ]; then
    echo -e "\n${YELLOW}[5/6] Skipping notarization${NC}"
else
    echo -e "\n${BLUE}[5/6] Notarizing...${NC}"
    echo "This may take a few minutes..."

    if [ "$USE_ENV_CREDENTIALS" = "true" ]; then
        xcrun notarytool submit "$DMG_FINAL" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_SPECIFIC_PASSWORD" \
            --wait
    else
        if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE_NAME" &>/dev/null; then
            [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ] && [ -n "$APP_SPECIFIC_PASSWORD" ] && \
                xcrun notarytool store-credentials "$NOTARY_PROFILE_NAME" \
                    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD"
        fi
        xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$NOTARY_PROFILE_NAME" --wait
    fi

    # Staple
    echo -e "\n${BLUE}Stapling notarization ticket...${NC}"
    xcrun stapler staple "$DMG_FINAL"
    echo -e "${GREEN}✓ Notarized${NC}"
fi

# Step 6: Verify
echo -e "\n${BLUE}[6/6] Verifying...${NC}"
spctl --assess --type open --context context:primary-signature "$DMG_FINAL" 2>&1 || true

rm -rf "$APP_BUNDLE"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Release build complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Output: ${BLUE}${DMG_FINAL}${NC}"
ls -lh "$DMG_FINAL"
echo ""

if [ "$SKIP_NOTARIZE" = "true" ]; then
    echo -e "${YELLOW}⚠️  Not notarized — users will see Gatekeeper warnings${NC}"
    echo "Set up notarization credentials and run again for full distribution."
fi
