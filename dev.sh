#!/bin/bash
set -e

APP_NAME="OMI-COMPUTER"
BUNDLE_ID="com.omi.computer-macos"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BACKEND_DIR="$(dirname "$0")/backend"
BACKEND_PID=""

# Cleanup function to stop backend on exit
cleanup() {
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Stopping backend (PID: $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Kill existing instances
pkill "$APP_NAME" 2>/dev/null || true
lsof -ti:8000 | xargs kill -9 2>/dev/null || true

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
    if curl -s http://localhost:8000 > /dev/null 2>&1; then
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
swift build -c debug

# Create app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp ".build/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy and fix Info.plist
cp Hartford/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Copy GoogleService-Info.plist for Firebase
cp Hartford/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"

# Copy .env.app (app runtime secrets only)
cp .env.app "$APP_BUNDLE/Contents/Resources/.env" 2>/dev/null || true

# Sign app (using Developer ID for distribution-style signing)
codesign --force --sign "Developer ID Application: Matthew Diakonov (S6DP5HF77G)" "$APP_BUNDLE"

echo "Dev build complete: $APP_BUNDLE"
echo "Backend running on http://localhost:8000 (PID: $BACKEND_PID)"
open "$APP_BUNDLE"

# Wait for backend process (keeps script running and shows logs)
echo "Press Ctrl+C to stop..."
wait "$BACKEND_PID"
