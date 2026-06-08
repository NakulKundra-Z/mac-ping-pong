#!/bin/bash
set -e

# Configuration
APP_NAME="NeonPingPong"
BUILD_DIR="build"
BUNDLE_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "=== Building ${APP_NAME} for Apple Silicon (M3) ==="

# 1. Clean and recreate bundle structure
echo "Recreating build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 2. Compile Swift source with optimizations
echo "Compiling main.swift with -O optimization..."
swiftc -O -parse-as-library -o "${MACOS_DIR}/${APP_NAME}" main.swift

# 3. Copy Plist
echo "Adding Info.plist..."
cp Info.plist "${CONTENTS_DIR}/Info.plist"

# 4. Generate AppIcon.icns if PNG exists
if [ -f "AppIcon.png" ]; then
    echo "Creating AppIcon.icns from AppIcon.png..."
    mkdir -p AppIcon.iconset
    sips -s format png -z 16 16     AppIcon.png --out AppIcon.iconset/icon_16x16.png
    sips -s format png -z 32 32     AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png
    sips -s format png -z 32 32     AppIcon.png --out AppIcon.iconset/icon_32x32.png
    sips -s format png -z 64 64     AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png
    sips -s format png -z 128 128   AppIcon.png --out AppIcon.iconset/icon_128x128.png
    sips -s format png -z 256 256   AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png
    sips -s format png -z 256 256   AppIcon.png --out AppIcon.iconset/icon_256x256.png
    sips -s format png -z 512 512   AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png
    sips -s format png -z 512 512   AppIcon.png --out AppIcon.iconset/icon_512x512.png
    sips -s format png -z 1024 1024 AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png
    
    iconutil -c icns AppIcon.iconset
    mv AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
    rm -rf AppIcon.iconset
    echo "AppIcon.icns generated successfully."
else
    echo "Warning: No AppIcon.png found. Bundle will use a generic icon."
fi

echo "=== Build Successful! ==="
echo "Application bundled at: ${BUNDLE_DIR}"
echo "You can launch the app by double-clicking it or running: open ${BUNDLE_DIR}"
