#!/bin/bash
set -e

APP_NAME="OMI-COMPUTER"
BUNDLE_ID="com.omi.computer-macos"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Kill existing instance
pkill "$APP_NAME" 2>/dev/null || true

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
open "$APP_BUNDLE"
