#!/bin/bash
set -e

# KiteGlance macOS Build Script
# Usage: ./build.sh [debug|release]

CONFIGURATION=${1:-release}
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
OUTPUT_DIR="$PROJECT_DIR/dist"

echo "Building KiteGlance for macOS ($CONFIGURATION)..."

# Generate assets if needed
if [ ! -f "$PROJECT_DIR/Sources/KiteGlance/Assets/Backdrops/backdrop-dawn.png" ]; then
    echo "Generating placeholder assets..."
    swift run --package-path "$PROJECT_DIR" generate-assets 2>/dev/null || {
        echo "Running asset generator script..."
        swift "$PROJECT_DIR/scripts/generate-assets.swift"
    }
fi

# Build
if [ "$CONFIGURATION" = "release" ]; then
    swift build --package-path "$PROJECT_DIR" -c release --arch arm64
else
    swift build --package-path "$PROJECT_DIR" -c debug --arch arm64
fi

# Copy executable
EXECUTABLE="$BUILD_DIR/arm64-apple-macosx/$CONFIGURATION/KiteGlance"
mkdir -p "$OUTPUT_DIR"
cp "$EXECUTABLE" "$OUTPUT_DIR/KiteGlance"

# Codesign for local testing (ad-hoc)
codesign --force --deep --sign - "$OUTPUT_DIR/KiteGlance" 2>/dev/null || true

echo ""
echo "Build complete!"
echo "Executable: $OUTPUT_DIR/KiteGlance"
echo ""
echo "To install locally:"
echo "  cp $OUTPUT_DIR/KiteGlance /Applications/KiteGlance.app/Contents/MacOS/KiteGlance"
echo ""
echo "Or run directly:"
echo "  $OUTPUT_DIR/KiteGlance"