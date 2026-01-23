#!/bin/bash
set -e

BUNDLE_ID="com.omi.focusmonitor"
APP_PATH="/Applications/OMI.app"

# Kill existing instance
pkill OMI 2>/dev/null || true

echo "Building..."
./build.sh

echo "Installing to /Applications..."
cp -r build/OMI.app /Applications/
codesign --force --deep --sign - "$APP_PATH"

echo "Resetting permissions for $BUNDLE_ID..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Notifications "$BUNDLE_ID" 2>/dev/null || true

echo "Revealing app in Finder..."
open -R "$APP_PATH"

echo "Starting app..."
open "$APP_PATH"

echo "Done. Grant permissions when prompted."
