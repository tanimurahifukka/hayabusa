#!/bin/bash
set -euo pipefail

# Create Hayabusa.app bundle and DMG installer
# Usage: ./scripts/create-dmg.sh [version]

VERSION="${1:-1.0.0}"
APP_NAME="Hayabusa"
BUNDLE_NAME="${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${BUILD_DIR}/dist"
APP_DIR="${OUTPUT_DIR}/${BUNDLE_NAME}"

echo "=== Building Hayabusa.app v${VERSION} ==="

# 1. Build the GUI app in release mode
echo "[1/5] Building HayabusaApp..."
cd "${BUILD_DIR}"
swift build -c release

# 2. Find the built binary
GUI_BINARY="${BUILD_DIR}/.build/release/HayabusaApp"
if [ ! -f "${GUI_BINARY}" ]; then
    echo "Error: GUI binary not found at ${GUI_BINARY}"
    exit 1
fi

# 3. Optionally include the server binary
SERVER_BINARY=""
HAYABUSA_ROOT="$(dirname "${BUILD_DIR}")"
if [ -f "${HAYABUSA_ROOT}/.build/release/Hayabusa" ]; then
    SERVER_BINARY="${HAYABUSA_ROOT}/.build/release/Hayabusa"
    echo "  Found server binary: ${SERVER_BINARY}"
fi

# 4. Create .app bundle structure
echo "[2/5] Creating app bundle..."
rm -rf "${OUTPUT_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy GUI binary
cp "${GUI_BINARY}" "${APP_DIR}/Contents/MacOS/HayabusaApp"

# Copy server binary if available
if [ -n "${SERVER_BINARY}" ]; then
    cp "${SERVER_BINARY}" "${APP_DIR}/Contents/MacOS/Hayabusa"
fi

# Copy Sparkle.framework
SPARKLE_FW="${BUILD_DIR}/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "${SPARKLE_FW}" ]; then
    mkdir -p "${APP_DIR}/Contents/Frameworks"
    cp -R "${SPARKLE_FW}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
    echo "  Embedded Sparkle.framework"
fi

# Copy Info.plist
cp "${BUILD_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_DIR}/Contents/Info.plist"

# Add rpath so the binary can find Frameworks/
install_name_tool -add_rpath @executable_path/../Frameworks "${APP_DIR}/Contents/MacOS/HayabusaApp" 2>/dev/null || true

# 5. Code sign (ad-hoc for local use)
echo "[3/5] Code signing..."
codesign --force --deep --sign - "${APP_DIR}"

# 6. Create DMG
echo "[4/5] Creating DMG..."
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"
TMP_DMG="${OUTPUT_DIR}/tmp.dmg"

# Create temporary DMG
hdiutil create -size 200m -fs HFS+ -volname "${APP_NAME}" "${TMP_DMG}"
MOUNT_DIR=$(hdiutil attach "${TMP_DMG}" | grep "Volumes" | awk '{print $3}')

# Copy app to DMG
cp -R "${APP_DIR}" "${MOUNT_DIR}/"

# Create Applications symlink for drag-and-drop install
ln -s /Applications "${MOUNT_DIR}/Applications"

# Set background and icon positions (optional, basic layout)
echo '
   tell application "Finder"
     tell disk "'${APP_NAME}'"
       open
       set current view of container window to icon view
       set toolbar visible of container window to false
       set statusbar visible of container window to false
       set bounds of container window to {400, 100, 900, 400}
       set theViewOptions to the icon view options of container window
       set arrangement of theViewOptions to not arranged
       set icon size of theViewOptions to 72
       set position of item "'${BUNDLE_NAME}'" of container window to {125, 150}
       set position of item "Applications" of container window to {375, 150}
       close
     end tell
   end tell
' | osascript || true

# Unmount and convert to compressed DMG
hdiutil detach "${MOUNT_DIR}"
hdiutil convert "${TMP_DMG}" -format UDZO -o "${DMG_PATH}"
rm -f "${TMP_DMG}"

echo "[5/5] Done!"
echo ""
echo "Output:"
echo "  App:  ${APP_DIR}"
echo "  DMG:  ${DMG_PATH}"
echo ""
echo "To install: open ${DMG_PATH} and drag Hayabusa to Applications"
