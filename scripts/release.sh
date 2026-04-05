#!/bin/bash

# DistributeMetal Release Orchestrator
#
# Full release lifecycle:
#   1. Bump VERSION (or use current)
#   2. Build signed + notarized DMG via build-release.sh
#   3. Create GitHub release with the DMG attached
#   4. Compute SHA256 and update the Homebrew cask in goldberg-consulting/homebrew-tap
#   5. Commit and push the cask update
#
# Usage:
#   bash scripts/release.sh              # release current VERSION
#   bash scripts/release.sh 0.2.0        # bump to 0.2.0, then release
#   bash scripts/release.sh patch        # auto-increment patch (0.1.0 -> 0.1.1)
#   bash scripts/release.sh minor        # auto-increment minor (0.1.0 -> 0.2.0)
#   bash scripts/release.sh major        # auto-increment major (0.1.0 -> 1.0.0)

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"
REPO="goldberg-consulting/distribute-metal"
TAP_REPO="goldberg-consulting/homebrew-tap"
CASK_PATH="Casks/distribute-metal.rb"

current_version() { cat "$VERSION_FILE" | tr -d '[:space:]'; }

bump_version() {
    local cur="$1" part="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$cur"

    case "$part" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
        *)     echo "$part" ;;
    esac
}

OLD_VERSION="$(current_version)"
NEW_VERSION="$OLD_VERSION"

if [ $# -ge 1 ]; then
    case "$1" in
        major|minor|patch)
            NEW_VERSION="$(bump_version "$OLD_VERSION" "$1")"
            ;;
        *)
            NEW_VERSION="$1"
            ;;
    esac
fi

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        DistributeMetal Release Orchestrator             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$NEW_VERSION" != "$OLD_VERSION" ]; then
    echo -e "${BLUE}Version bump: ${OLD_VERSION} -> ${NEW_VERSION}${NC}"
    echo "$NEW_VERSION" > "$VERSION_FILE"
else
    echo -e "${BLUE}Version: ${NEW_VERSION}${NC}"
fi

DMG_NAME="DistributeMetal-${NEW_VERSION}.dmg"
DMG_PATH="$PROJECT_ROOT/dist/$DMG_NAME"
TAG="v${NEW_VERSION}"

# ── Step 1: Build ────────────────────────────────────────────────────────────

echo -e "\n${BLUE}[1/5] Building signed + notarized DMG...${NC}"
bash "$SCRIPT_DIR/build-release.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo -e "${RED}Expected DMG not found at ${DMG_PATH}${NC}"
    exit 1
fi
echo -e "${GREEN}DMG: ${DMG_PATH} ($(du -h "$DMG_PATH" | cut -f1))${NC}"

# ── Step 2: Commit version bump ─────────────────────────────────────────────

echo -e "\n${BLUE}[2/5] Committing version bump...${NC}"
cd "$PROJECT_ROOT"

if ! git diff --quiet VERSION 2>/dev/null; then
    git add VERSION
    git commit -m "Bump version to ${NEW_VERSION}"
    git push
    echo -e "${GREEN}Pushed version bump${NC}"
else
    echo -e "${YELLOW}VERSION unchanged, skipping commit${NC}"
fi

# ── Step 3: GitHub release ───────────────────────────────────────────────────

echo -e "\n${BLUE}[3/5] Creating GitHub release ${TAG}...${NC}"

if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
    echo -e "${YELLOW}Release ${TAG} already exists. Uploading DMG as additional asset...${NC}"
    gh release upload "$TAG" "$DMG_PATH" --repo "$REPO" --clobber
else
    gh release create "$TAG" "$DMG_PATH" \
        --repo "$REPO" \
        --title "DistributeMetal ${TAG}" \
        --notes "Release ${NEW_VERSION}. See [README](https://github.com/${REPO}#readme) for install instructions."
fi
echo -e "${GREEN}Release: https://github.com/${REPO}/releases/tag/${TAG}${NC}"

# ── Step 4: Compute SHA256 ──────────────────────────────────────────────────

echo -e "\n${BLUE}[4/5] Computing SHA256...${NC}"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo -e "${GREEN}SHA256: ${SHA256}${NC}"

# ── Step 5: Update Homebrew cask ─────────────────────────────────────────────

echo -e "\n${BLUE}[5/5] Updating Homebrew cask...${NC}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

gh repo clone "$TAP_REPO" "$WORK_DIR/homebrew-tap" -- --depth=1 2>/dev/null

CASK_FILE="$WORK_DIR/homebrew-tap/$CASK_PATH"

if [ ! -f "$CASK_FILE" ]; then
    echo -e "${RED}Cask file not found at ${CASK_PATH} in ${TAP_REPO}${NC}"
    exit 1
fi

OLD_CASK_VERSION=$(grep 'version "' "$CASK_FILE" | head -1 | sed 's/.*version "\(.*\)"/\1/')
OLD_CASK_SHA=$(grep 'sha256 "' "$CASK_FILE" | head -1 | sed 's/.*sha256 "\(.*\)"/\1/')

echo -e "  Cask version: ${OLD_CASK_VERSION} -> ${NEW_VERSION}"
echo -e "  Cask sha256:  ${OLD_CASK_SHA:0:16}... -> ${SHA256:0:16}..."

sed -i '' "s/version \"${OLD_CASK_VERSION}\"/version \"${NEW_VERSION}\"/" "$CASK_FILE"
sed -i '' "s/sha256 \"${OLD_CASK_SHA}\"/sha256 \"${SHA256}\"/" "$CASK_FILE"

cd "$WORK_DIR/homebrew-tap"
if ! git diff --quiet; then
    git add "$CASK_PATH"
    git commit -m "Update distribute-metal to ${NEW_VERSION}"
    git push
    echo -e "${GREEN}Cask updated and pushed${NC}"
else
    echo -e "${YELLOW}Cask already at ${NEW_VERSION}, no changes needed${NC}"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Release ${TAG} complete.${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "GitHub:   https://github.com/${REPO}/releases/tag/${TAG}"
echo -e "Homebrew: brew install ${TAP_REPO/homebrew-/}/distribute-metal"
echo -e "DMG:      ${DMG_PATH}"
echo ""
