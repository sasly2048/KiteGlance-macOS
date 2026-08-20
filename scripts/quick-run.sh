#!/bin/bash
# quick-run.sh — Build and run locally without signing (for development)
# Run this on macOS during development

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== KiteGlance Development Build ==="

# Generate assets if needed
if [[ ! -f "Sources/KiteGlance/Assets/Backdrops/backdrop-dawn.png" ]]; then
    echo "Generating assets..."
    swift run generate-assets 2>/dev/null || swift scripts/generate-assets.swift
fi

# Build debug (faster)
echo "Building debug..."
swift build -c debug --arch arm64

# Create minimal app bundle for testing
APP_BUNDLE="$PROJECT_DIR/.build/debug/KiteGlance.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/arm64-apple-macosx/debug/KiteGlance" "$APP_BUNDLE/Contents/MacOS/KiteGlance"
cp "Sources/KiteGlance/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc sign for local testing (required for network access on macOS)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null

echo ""
echo "=== Ready to run ==="
echo "App bundle: $APP_BUNDLE"
echo ""
echo "Run it:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "Or run directly from terminal (see logs):"
echo "  \"$APP_BUNDLE/Contents/MacOS/KiteGlance\""
echo ""
echo "Logs: ~/Library/Application Support/KiteGlance/logs/kiteglance.log"