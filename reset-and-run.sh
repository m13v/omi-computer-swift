#!/bin/bash
set -e

# Clear system OPENAI_API_KEY so .env takes precedence
unset OPENAI_API_KEY

# App configuration
APP_NAME="Omi Computer"
BUNDLE_ID="com.omi.computer-macos.development"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_PATH="/Applications/$APP_NAME.app"
SIGN_IDENTITY="Developer ID Application: Matthew Diakonov (S6DP5HF77G)"

# Backend configuration (Rust)
BACKEND_DIR="$(dirname "$0")/Backend-Rust"
BACKEND_PID=""
TUNNEL_PID=""
TUNNEL_URL="https://omi-dev.m13v.com"

# Cleanup function to stop backend and tunnel on exit
cleanup() {
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "Stopping tunnel (PID: $TUNNEL_PID)..."
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Stopping backend (PID: $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Kill existing instances
echo "Killing existing instances..."
pkill "$APP_NAME" 2>/dev/null || true
pkill "Omi" 2>/dev/null || true
pkill -f "cloudflared.*omi-computer-dev" 2>/dev/null || true
lsof -ti:8080 | xargs kill -9 2>/dev/null || true

# Clear log file for fresh run (must be before backend starts)
rm -f /tmp/omi.log 2>/dev/null || true

# Clean up conflicting app bundles with same bundle ID
echo "Cleaning up conflicting app bundles..."
CONFLICTING_APPS=(
    "/Applications/Omi.app"
    "/Applications/Omi Computer.app"
    "$APP_BUNDLE"  # Local build folder
    "$HOME/Desktop/Omi.app"
    "$HOME/Downloads/Omi.app"
    # Flutter app builds (with and without -prod suffix)
    "$(dirname "$0")/../omi/app/build/macos/Build/Products/Debug/Omi.app"
    "$(dirname "$0")/../omi/app/build/macos/Build/Products/Release/Omi.app"
    "$(dirname "$0")/../omi/app/build/macos/Build/Products/Debug-prod/Omi.app"
    "$(dirname "$0")/../omi/app/build/macos/Build/Products/Release-prod/Omi.app"
    "$(dirname "$0")/../omi-computer/build/macos/Build/Products/Debug/Omi.app"
    "$(dirname "$0")/../omi-computer/build/macos/Build/Products/Release/Omi.app"
)
# Also clean Xcode DerivedData for Omi builds
echo "Cleaning Xcode DerivedData..."
find "$HOME/Library/Developer/Xcode/DerivedData" -name "Omi.app" -type d 2>/dev/null | while read app; do
    echo "  Removing: $app"
    rm -rf "$app"
done
find "$HOME/Library/Developer/Xcode/DerivedData" -name "Omi Computer.app" -type d 2>/dev/null | while read app; do
    echo "  Removing: $app"
    rm -rf "$app"
done

# Clean DMG staging directories (leftover from release builds)
echo "Cleaning DMG staging directories..."
rm -rf /private/tmp/omi-dmg-staging-* /private/tmp/omi-dmg-test-* 2>/dev/null || true

# Clean Omi apps from Trash (they pollute Launch Services)
echo "Cleaning Omi apps from Trash..."
rm -rf "$HOME/.Trash/OMI"* "$HOME/.Trash/Omi"* 2>/dev/null || true

# Eject any mounted Omi DMG volumes (they also pollute Launch Services)
echo "Ejecting mounted Omi DMG volumes..."
for vol in /Volumes/Omi* /Volumes/OMI* /Volumes/dmg.*; do
    if [ -d "$vol" ]; then
        echo "  Ejecting: $vol"
        diskutil eject "$vol" 2>/dev/null || hdiutil detach "$vol" 2>/dev/null || true
    fi
done

for app in "${CONFLICTING_APPS[@]}"; do
    if [ -d "$app" ]; then
        echo "  Removing: $app"
        rm -rf "$app"
    fi
done

# Reset Launch Services database to clear cached bundle ID mappings
echo "Resetting Launch Services database..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain user 2>/dev/null || true

# Reset TCC permissions BEFORE building new app (while no app exists with this bundle ID)
# This ensures clean slate for the new app
BUNDLE_ID_PROD="com.omi.computer-macos"
echo "Resetting TCC permissions (before build)..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID_PROD" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID_PROD" 2>/dev/null || true
tccutil reset AppleEvents "$BUNDLE_ID" 2>/dev/null || true
tccutil reset AppleEvents "$BUNDLE_ID_PROD" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID_PROD" 2>/dev/null || true

# Clean user TCC database directly
echo "Cleaning user TCC database..."
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "DELETE FROM access WHERE client LIKE '%com.omi.computer-macos%';" 2>/dev/null || true

# Start Cloudflare tunnel
echo "Starting Cloudflare tunnel..."
cloudflared tunnel run omi-computer-dev &
TUNNEL_PID=$!
sleep 2

# Start Rust backend
echo "Starting Rust backend..."
cd "$BACKEND_DIR"

# Copy .env if not present
if [ ! -f ".env" ] && [ -f "../Backend/.env" ]; then
    cp "../Backend/.env" ".env"
fi

# Symlink google-credentials.json if not present
if [ ! -f "google-credentials.json" ] && [ -f "../Backend/google-credentials.json" ]; then
    ln -sf "../Backend/google-credentials.json" "google-credentials.json"
fi

# Build if binary doesn't exist or source is newer
if [ ! -f "target/release/omi-desktop-backend" ] || [ -n "$(find src -newer target/release/omi-desktop-backend 2>/dev/null)" ]; then
    echo "Building Rust backend..."
    cargo build --release
fi

./target/release/omi-desktop-backend &
BACKEND_PID=$!
cd - > /dev/null

# Wait for backend to be ready
echo "Waiting for backend to start..."
for i in {1..30}; do
    if curl -s http://localhost:8080 > /dev/null 2>&1; then
        echo "Backend is ready!"
        break
    fi
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Backend failed to start"
        exit 1
    fi
    sleep 0.5
done

# Build debug
echo "Building app..."
swift build -c debug --package-path Desktop

# Remove old app bundle to avoid permission issues with signed apps
rm -rf "$APP_BUNDLE"

# Create app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "Desktop/.build/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Add rpath for Frameworks folder (needed for Sparkle)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Copy Sparkle framework (keep original signatures intact)
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK="Desktop/.build/arm64-apple-macosx/debug/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo "  Copied Sparkle.framework"
fi

# Copy resource bundle (contains app assets like permissions.gif, herologo.png, etc.)
RESOURCE_BUNDLE="Desktop/.build/arm64-apple-macosx/debug/Omi Computer_Omi Computer.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -Rf "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "  Copied resource bundle"
fi

# Copy and fix Info.plist
cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Omi Computer" "$APP_BUNDLE/Contents/Info.plist"

# Copy GoogleService-Info.plist for Firebase
cp Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"

# Copy .env.app (app runtime secrets only) and add API URL
if [ -f ".env.app" ]; then
    cp .env.app "$APP_BUNDLE/Contents/Resources/.env"
else
    touch "$APP_BUNDLE/Contents/Resources/.env"
fi
# Set API URL to tunnel for development (overrides production default)
echo "OMI_API_URL=$TUNNEL_URL" >> "$APP_BUNDLE/Contents/Resources/.env"
echo "Using backend: $TUNNEL_URL"

# Copy app icon
cp omi_icon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Strip extended attributes before signing (prevents "resource fork, Finder information" errors)
xattr -cr "$APP_BUNDLE"

# Sign Sparkle framework components individually (like release.sh does)
echo "Signing Sparkle framework components..."
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    # Sign innermost components first
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Updater.app" 2>/dev/null || true
    # Sign framework itself
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
fi

# Sign main app
echo "Signing app..."
codesign --force --options runtime --entitlements Desktop/Omi.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

# Install to /Applications
echo "Installing to /Applications..."
rm -rf "$APP_PATH"
ditto "$APP_BUNDLE" "$APP_PATH"

# Reset app data (UserDefaults, onboarding state, etc.) for BOTH bundle IDs
# (TCC permissions were already reset before building)
echo "Resetting app data..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults delete "$BUNDLE_ID_PROD" 2>/dev/null || true

# Clear delivered notifications
echo "Clearing notifications..."
osascript -e "tell application \"System Events\" to tell process \"NotificationCenter\" to click button 1 of every window" 2>/dev/null || true

# Note: Notification PERMISSIONS cannot be reset programmatically (Apple limitation)
# To fully reset notification permissions, manually go to:
# System Settings > Notifications > Omi Computer > Remove
echo "Note: Notification permissions can only be reset manually in System Settings"

echo ""
echo "=== Services Running ==="
echo "Backend:  http://localhost:8080 (PID: $BACKEND_PID)"
echo "Tunnel:   $TUNNEL_URL (PID: $TUNNEL_PID)"
echo "App:      $APP_PATH"
echo "========================"
echo ""

# Remove quarantine and start app from /Applications
echo "Starting app..."
xattr -cr "$APP_PATH"
open "$APP_PATH" || "$APP_PATH/Contents/MacOS/$APP_NAME" &

# Wait for backend process (keeps script running and shows logs)
echo "Press Ctrl+C to stop all services..."
wait "$BACKEND_PID"
