#!/bin/bash
set -e

###############################################################################
# BUILD LOCAL PRODUCTION VERSION FOR TESTING
# Builds with production bundle ID but doesn't release or notarize
###############################################################################

APP_NAME="Omi Computer"
BUNDLE_ID="com.omi.computer-macos"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_PATH="/Applications/$APP_NAME.app"
SIGN_IDENTITY="Developer ID Application: Matthew Diakonov (S6DP5HF77G)"
VERSION="0.0.0-local"

echo "=============================================="
echo "  Building Local Production Version"
echo "  Bundle ID: $BUNDLE_ID"
echo "=============================================="
echo ""

# Kill existing app
echo "[1/6] Stopping existing app..."
pkill -f "Omi Computer" 2>/dev/null || true
sleep 1

# Reset TCC permissions for production bundle (while app still exists)
echo "[2/6] Resetting TCC permissions..."
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true

# Clean up conflicting bundles
echo "[3/6] Cleaning up conflicting bundles..."
rm -rf "$APP_PATH" 2>/dev/null || true
rm -rf "$APP_BUNDLE" 2>/dev/null || true

# Clean DMG staging and mounted volumes
rm -rf /private/tmp/omi-dmg-staging-* 2>/dev/null || true
for vol in /Volumes/Omi* /Volumes/dmg.*; do
    if [ -d "$vol" ] 2>/dev/null; then
        diskutil eject "$vol" 2>/dev/null || hdiutil detach "$vol" 2>/dev/null || true
    fi
done

# Reset Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain user 2>/dev/null || true

# Build release
echo "[4/6] Building release binary..."
swift build -c release --package-path Desktop

# Create app bundle
echo "[5/6] Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

BINARY_PATH=$(swift build -c release --package-path Desktop --show-bin-path)/"$APP_NAME"
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Sparkle framework
SPARKLE_FRAMEWORK="$(swift build -c release --package-path Desktop --show-bin-path)/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

# Add rpath for Sparkle
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Copy resources
cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"

# Copy resource bundle
SWIFT_BUILD_DIR=$(swift build -c release --package-path Desktop --show-bin-path)
if [ -d "$SWIFT_BUILD_DIR/Omi Computer_Omi Computer.bundle" ]; then
    cp -R "$SWIFT_BUILD_DIR/Omi Computer_Omi Computer.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

# Copy icon
cp omi_icon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# Copy .env.app
if [ -f ".env.app" ]; then
    cp ".env.app" "$APP_BUNDLE/Contents/Resources/.env"
fi

# Update Info.plist with production bundle ID
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Omi Computer" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_BUNDLE/Contents/Info.plist"

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Strip extended attributes and sign
echo "[6/6] Signing app..."
xattr -cr "$APP_BUNDLE"

# Sign Sparkle components
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Updater.app" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
fi

# Sign main app with release entitlements
codesign --force --options runtime --entitlements Desktop/Omi-Release.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

# Install to /Applications
echo ""
echo "Installing to /Applications..."
rm -rf "$APP_PATH"
ditto "$APP_BUNDLE" "$APP_PATH"

# Re-register with Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH"

# Reset UserDefaults for fresh onboarding
defaults delete "$BUNDLE_ID" 2>/dev/null || true

# Remove quarantine and launch
xattr -cr "$APP_PATH"

echo ""
echo "=============================================="
echo "  Build Complete!"
echo "=============================================="
echo ""
echo "App installed: $APP_PATH"
echo "Bundle ID: $BUNDLE_ID"
echo ""
echo "Starting app..."
open "$APP_PATH"
