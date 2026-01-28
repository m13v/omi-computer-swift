#!/bin/bash
set -e

# App configuration
APP_NAME="OMI-COMPUTER"
BUNDLE_ID="com.omi.computer-macos"
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

# Clean up conflicting app bundles with same bundle ID
echo "Cleaning up conflicting app bundles..."
CONFLICTING_APPS=(
    "/Applications/Omi.app"
    "$HOME/Desktop/Omi.app"
    "$HOME/Downloads/Omi.app"
    "$(dirname "$0")/../omi/app/build/macos/Build/Products/Debug/Omi.app"
    "$(dirname "$0")/../omi/app/build/macos/Build/Products/Release/Omi.app"
    "$(dirname "$0")/../omi-computer/build/macos/Build/Products/Debug/Omi.app"
    "$(dirname "$0")/../omi-computer/build/macos/Build/Products/Release/Omi.app"
)
for app in "${CONFLICTING_APPS[@]}"; do
    if [ -d "$app" ]; then
        echo "  Removing: $app"
        rm -rf "$app"
    fi
done

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

# Create/update app bundle in place (preserves TCC permissions)
echo "Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp -f "Desktop/.build/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy and fix Info.plist
cp -f Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Copy GoogleService-Info.plist for Firebase
cp -f Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"

# Copy .env.app (app runtime secrets only)
cp -f .env.app "$APP_BUNDLE/Contents/Resources/.env" 2>/dev/null || true

# Copy app icon
cp -f omi_icon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# Sign app with ad-hoc signature (for local development)
echo "Signing app (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "=== Services Running ==="
echo "Backend:  http://localhost:8080 (PID: $BACKEND_PID)"
echo "Tunnel:   $TUNNEL_URL (PID: $TUNNEL_PID)"
echo "App:      $APP_BUNDLE (running from build directory)"
echo "========================"
echo ""

# Clear log file for fresh run
rm -f /tmp/omi.log 2>/dev/null || true

# Remove quarantine and start app from build directory
echo "Starting app..."
xattr -cr "$APP_BUNDLE"
open "$APP_BUNDLE" || "$APP_BUNDLE/Contents/MacOS/$APP_NAME" &

# Wait for backend process (keeps script running and shows logs)
echo "Press Ctrl+C to stop all services..."
wait "$BACKEND_PID"
