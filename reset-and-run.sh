#!/bin/bash
set -e

BUNDLE_ID="com.omi.focusmonitor"
APP_PATH="/Applications/OMI.app"
SIGN_IDENTITY="Developer ID Application: Matthew Diakonov (S6DP5HF77G)"

# Parse arguments
SIGNED=false
if [ "$1" = "--signed" ] || [ "$1" = "-s" ]; then
    SIGNED=true
fi

# Kill existing instance
pkill OMI 2>/dev/null || true

echo "Building..."
./build.sh

echo "Installing to /Applications..."
cp -r build/OMI.app /Applications/

if [ "$SIGNED" = true ]; then
    echo "Signing with Developer ID..."
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        --entitlements Hartford/Hartford.entitlements \
        "$APP_PATH"
else
    echo "Ad-hoc signing (use --signed for Developer ID)..."
    codesign --force --deep --sign - "$APP_PATH"
fi

echo "Resetting permissions for $BUNDLE_ID..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Notifications "$BUNDLE_ID" 2>/dev/null || true

echo "Revealing app in Finder..."
open -R "$APP_PATH"

echo "Starting app..."
open "$APP_PATH"

echo "Done. Grant permissions when prompted."
