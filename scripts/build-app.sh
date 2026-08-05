#!/bin/bash
# build-app.sh — Builds a complete, signed, notarizable KiteGlance.app bundle
# Run this on macOS 15+ with Xcode 16+ installed
#
# Usage:
#   ./build-app.sh [--sign "Developer ID Application: Name (TEAMID)"] [--notarize --keychain-profile "profile"]
#   ./build-app.sh                    # Unsigned, for local testing
#   ./build-app.sh --sign "..."       # Signed, ready for notarization
#   ./build-app.sh --sign "..." --notarize --keychain-profile "notary-profile"  # Full pipeline

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="KiteGlance"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION="1.0.0"
BUILD_NUM="1"
IDENTIFIER="com.kiteglance"

# Parse args
SIGN_IDENTITY=""
NOTARIZE=false
KEYCHAIN_PROFILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --notarize) NOTARIZE=true; shift ;;
        --keychain-profile) KEYCHAIN_PROFILE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ "$NOTARIZE" == true && -z "$KEYCHAIN_PROFILE" ]]; then
    echo "Error: --notarize requires --keychain-profile"
    exit 1
fi

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Warning: --sign should be a Developer ID Application identity"
fi

# ── Helpers ─────────────────────────────────────────────────────────────
log()  { printf "\033[1;34m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*"; }

# ── 1. Generate Assets ──────────────────────────────────────────────────
log "Generating assets..."
cd "$PROJECT_DIR"
if [[ ! -f "Sources/KiteGlance/Assets/Backdrops/backdrop-dawn.png" ]]; then
    # Best-effort: the app falls back to gradients when the PNGs are absent, so
    # a failure here must not abort the build (the script runs under `set -e`).
    swift run generate-assets || warn "Asset generation failed; using built-in gradients"
fi
ok "Assets ready"

# ── 2. Build Release Binary ─────────────────────────────────────────────
log "Building release binary (arm64)..."
swift build -c release --arch arm64
BINARY="$BUILD_DIR/arm64-apple-macosx/release/KiteGlance"
[[ -f "$BINARY" ]] || { err "Binary not found at $BINARY"; exit 1; }
ok "Binary built: $BINARY"

# ── 3. Create App Bundle Structure ──────────────────────────────────────
log "Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ok "Executable copied"

# Copy Info.plist
cp "$PROJECT_DIR/Sources/KiteGlance/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP_BUNDLE/Contents/Info.plist"
ok "Info.plist updated"

# ── 4. Create App Icon (.icns) ──────────────────────────────────────────
log "Creating AppIcon.icns..."
ICONSET_PARENT=$(mktemp -d)
ICONSET_DIR="$ICONSET_PARENT/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

SRC_PNG="$PROJECT_DIR/Sources/KiteGlance/Assets/Icons/app-icon.png"

# The previous version wrote a truncated base64 blob into a .png and then
# reassigned SRC_PNG back to the same missing path, so sips failed on every
# size and iconutil got an empty iconset. Skip the icon instead of shipping a
# corrupt one -- a bundle with no icon still launches.
if [[ ! -f "$SRC_PNG" ]]; then
    warn "No source icon at $SRC_PNG; building without a custom AppIcon"
else
    for size in 16 32 64 128 256 512; do
        sips -z $size $size "$SRC_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null 2>&1
        sips -z $((size*2)) $((size*2)) "$SRC_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done

    if iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        ok "AppIcon.icns created"
    else
        warn "iconutil failed; continuing without a custom AppIcon"
    fi
fi
rm -rf "$ICONSET_PARENT"

# ── 5. Copy SwiftPM resource bundle ──────────────────────────────────────
# SwiftPM emits KiteGlance_KiteGlance.bundle next to the binary. Without it,
# Bundle.module traps at runtime and every backdrop lookup fails.
RESOURCE_BUNDLE="$BUILD_DIR/arm64-apple-macosx/release/KiteGlance_KiteGlance.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    ok "Resource bundle copied"
else
    warn "Resource bundle not found at $RESOURCE_BUNDLE"
fi

# Entitlements are a signing input, not a bundle resource -- shipping them
# inside Resources/ does nothing but leak the capability list.

# ── 6. Code Sign ────────────────────────────────────────────────────────
if [[ -n "$SIGN_IDENTITY" ]]; then
    log "Code signing with: $SIGN_IDENTITY"
    codesign --force --deep --options runtime \
        --entitlements "$PROJECT_DIR/KiteGlance.entitlements" \
        --sign "$SIGN_IDENTITY" \
        --timestamp \
        "$APP_BUNDLE"
    ok "Code signed"

    # Verify signature
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -5
    spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || true
else
    warn "Skipping code sign (no --sign identity provided)"
    # Ad-hoc sign for local testing
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
    ok "Ad-hoc signed for local testing"
fi

# ── 7. Create DMG (optional, for distribution) ──────────────────────────
if [[ -n "$SIGN_IDENTITY" ]]; then
    log "Creating DMG..."
    DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    create-dmg \
        --volname "$APP_NAME $VERSION" \
        --volicon "$APP_BUNDLE/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 190 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 190 \
        --eula "$PROJECT_DIR/LICENSE" \
        "$DMG_PATH" \
        "$DIST_DIR/" 2>/dev/null || {
        # Fallback: simple DMG without create-dmg
        hdiutil create -volname "$APP_NAME $VERSION" \
            -srcfolder "$APP_BUNDLE" \
            -ov -format UDZO \
            "$DMG_PATH" >/dev/null
    }
    ok "DMG created: $DMG_PATH"

    # Sign DMG
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
    ok "DMG signed"
fi

# ── 8. Notarize ─────────────────────────────────────────────────────────
if [[ "$NOTARIZE" == true ]]; then
    log "Submitting for notarization..."
    SUBMISSION_ID=$(xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait \
        --output-format json | jq -r '.id')

    if [[ -z "$SUBMISSION_ID" || "$SUBMISSION_ID" == "null" ]]; then
        err "Notarization submission failed"
        exit 1
    fi

    log "Notarization complete, stapling..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler staple "$DMG_PATH"
    ok "Stapled successfully"
fi

# ── Done ────────────────────────────────────────────────────────────────
echo ""
ok "Build complete!"
echo "  App bundle: $APP_BUNDLE"
[[ -n "$SIGN_IDENTITY" ]] && echo "  DMG:        $DMG_PATH"
echo ""
echo "To test locally:"
echo "  open $APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -R $APP_BUNDLE /Applications/"