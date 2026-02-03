#!/bin/bash
set -e

APP_NAME="Omi Computer"
BUNDLE_ID="com.omi.computer-macos.development"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BACKEND_DIR="$(dirname "$0")/Backend"
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
pkill "$APP_NAME" 2>/dev/null || true
pkill -f "cloudflared.*omi-computer-dev" 2>/dev/null || true
lsof -ti:8080 | xargs kill -9 2>/dev/null || true

# Start Cloudflare tunnel
echo "Starting Cloudflare tunnel..."
cloudflared tunnel run omi-computer-dev &
TUNNEL_PID=$!
sleep 2

# Start backend
echo "Starting backend..."
cd "$BACKEND_DIR"
if [ ! -d "venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
else
    source venv/bin/activate
fi
python main.py &
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
swift build -c debug --package-path Desktop

# Create app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "Desktop/.build/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

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
cp -f omi_icon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Sign app (using Developer ID for distribution-style signing)
codesign --force --sign "Developer ID Application: Matthew Diakonov (S6DP5HF77G)" "$APP_BUNDLE"

echo "Dev build complete: $APP_BUNDLE"
echo ""
echo "=== Services Running ==="
echo "Backend:  http://localhost:8080 (PID: $BACKEND_PID)"
echo "Tunnel:   $TUNNEL_URL (PID: $TUNNEL_PID)"
echo "========================"
echo ""
open "$APP_BUNDLE"

# Wait for backend process (keeps script running and shows logs)
echo "Press Ctrl+C to stop..."
wait "$BACKEND_PID"
