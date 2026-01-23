#!/bin/bash
set -e

APP_NAME="OMI"
BUNDLE_ID="com.omi.focusmonitor"
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
cp ".build/arm64-apple-macosx/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy and fix Info.plist
cp Hartford/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Copy .env
cp .env "$APP_BUNDLE/Contents/Resources/.env" 2>/dev/null || true

echo "Dev build complete: $APP_BUNDLE"
open "$APP_BUNDLE"
