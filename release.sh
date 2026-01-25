#!/bin/bash
set -e

# =============================================================================
# OMI Release Script
# Full pipeline: build → sign → notarize → package DMG → publish to CrabNebula
# Usage: ./release.sh <version>
# Example: ./release.sh 0.0.3
# =============================================================================

# Check version argument
if [ -z "$1" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 0.0.3"
    exit 1
fi

VERSION="$1"

# Configuration
APP_NAME="OMI-COMPUTER"
BUNDLE_ID="com.omi.computer-macos"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

# Signing & notarization
SIGN_IDENTITY="Developer ID Application: Matthew Diakonov (S6DP5HF77G)"
TEAM_ID="S6DP5HF77G"
APPLE_ID="matthew.heartful@gmail.com"
NOTARIZE_PASSWORD="${NOTARIZE_PASSWORD:-REDACTED}"

# CrabNebula
CN_CLI="${CN_CLI:-$HOME/.local/bin/cn}"
CN_ORG="mediar"
CN_APP="omi-computer"
export CN_API_KEY="${CN_API_KEY:-cn_4j2Us_EaFAXfV-IKtesjLt7T6tecbKMuKJWRMVfX45e0GMz4mQWwOYoNG_TMZxa6Fw7YDV-sNM3NRuWPMczNAg}"

echo "=============================================="
echo "  OMI Release Pipeline v$VERSION"
echo "=============================================="
echo ""

# -----------------------------------------------------------------------------
# Step 1: Build
# -----------------------------------------------------------------------------
echo "[1/9] Building $APP_NAME..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

swift build -c release

BINARY_PATH=$(swift build -c release --show-bin-path)/$APP_NAME
if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi

# Create app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Omi/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy icon if exists
if [ -f "omi_icon.icns" ]; then
    cp omi_icon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Copy GoogleService-Info.plist for Firebase
cp Omi/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"

# Update Info.plist with version and bundle info
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$APP_BUNDLE/Contents/Info.plist"

# Copy .env.app (app runtime secrets only - not build secrets)
if [ -f ".env.app" ]; then
    cp ".env.app" "$APP_BUNDLE/Contents/Resources/.env"
    echo "  Copied .env.app to bundle"
else
    echo "  Warning: No .env.app file found"
fi

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "  ✓ Build complete"

# -----------------------------------------------------------------------------
# Step 2: Sign App
# -----------------------------------------------------------------------------
echo "[2/9] Signing app with Developer ID..."

codesign --force --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements Omi/Omi-Release.entitlements \
    "$APP_BUNDLE"

codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | head -3
echo "  ✓ App signed"

# -----------------------------------------------------------------------------
# Step 3: Notarize App
# -----------------------------------------------------------------------------
echo "[3/9] Notarizing app (this may take a minute)..."

# Create temporary zip for notarization
TEMP_ZIP="$BUILD_DIR/notarize-temp.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$TEMP_ZIP"

xcrun notarytool submit "$TEMP_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$NOTARIZE_PASSWORD" \
    --wait

rm -f "$TEMP_ZIP"
echo "  ✓ App notarized"

# -----------------------------------------------------------------------------
# Step 4: Staple App
# -----------------------------------------------------------------------------
echo "[4/9] Stapling notarization ticket to app..."

xcrun stapler staple "$APP_BUNDLE"
echo "  ✓ App stapled"

# -----------------------------------------------------------------------------
# Step 5: Create DMG (with Applications shortcut for drag-to-install)
# -----------------------------------------------------------------------------
echo "[5/9] Creating installer DMG..."

rm -f "$DMG_PATH"

# Copy app to temp staging directory to avoid permission issues
STAGING_DIR="/tmp/omi-dmg-staging-$$"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
STAGED_APP="$STAGING_DIR/$APP_NAME.app"

# Use create-dmg for a proper installer DMG with Applications shortcut
if command -v create-dmg &> /dev/null; then
    # Use background image if available
    BG_ARGS=""
    if [ -f "dmg-assets/background.png" ]; then
        BG_ARGS="--background dmg-assets/background.png"
    fi

    create-dmg \
        --volname "Application" \
        --volicon "$STAGED_APP/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 610 365 \
        --icon-size 80 \
        --icon "$APP_NAME.app" 155 175 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 455 175 \
        --no-internet-enable \
        $BG_ARGS \
        "$DMG_PATH" \
        "$STAGED_APP"
else
    # Fallback to basic hdiutil if create-dmg not available
    echo "  Warning: create-dmg not found, using basic DMG creation"
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$STAGED_APP" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

# Clean up staging directory
rm -rf "$STAGING_DIR"

echo "  ✓ DMG created"

# -----------------------------------------------------------------------------
# Step 6: Sign DMG
# -----------------------------------------------------------------------------
echo "[6/9] Signing DMG..."

codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
echo "  ✓ DMG signed"

# -----------------------------------------------------------------------------
# Step 7: Notarize DMG
# -----------------------------------------------------------------------------
echo "[7/9] Notarizing DMG..."

xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$NOTARIZE_PASSWORD" \
    --wait

echo "  ✓ DMG notarized"

# -----------------------------------------------------------------------------
# Step 8: Staple DMG
# -----------------------------------------------------------------------------
echo "[8/9] Stapling notarization ticket to DMG..."

xcrun stapler staple "$DMG_PATH"
echo "  ✓ DMG stapled"

# -----------------------------------------------------------------------------
# Step 9: Publish to CrabNebula
# -----------------------------------------------------------------------------
echo "[9/9] Publishing to CrabNebula..."

if [ ! -f "$CN_CLI" ]; then
    echo "  Error: CrabNebula CLI not found at $CN_CLI"
    echo "  Install with: curl -L https://cdn.crabnebula.app/download/crabnebula/cn-cli/latest/cn_macos -o ~/.local/bin/cn && chmod +x ~/.local/bin/cn"
    exit 1
fi

# Create draft
"$CN_CLI" release draft "$CN_ORG/$CN_APP" "$VERSION" 2>/dev/null || true

# Upload DMG
"$CN_CLI" release upload "$CN_ORG/$CN_APP" "$VERSION" --file "$DMG_PATH"

# Publish
"$CN_CLI" release publish "$CN_ORG/$CN_APP" "$VERSION"

echo "  ✓ Published to CrabNebula"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Release $VERSION Complete!"
echo "=============================================="
echo ""
echo "Local files:"
echo "  App: $APP_BUNDLE"
echo "  DMG: $DMG_PATH"
echo ""
echo "Download URL:"
echo "  https://cdn.crabnebula.app/download/$CN_ORG/$CN_APP/latest/$APP_NAME.dmg"
echo ""
echo "Verify with:"
echo "  spctl --assess --verbose=2 $APP_BUNDLE"
echo "  spctl --assess --verbose=2 --type open --context context:primary-signature $DMG_PATH"
echo ""
