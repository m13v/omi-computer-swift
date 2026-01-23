#!/bin/bash
set -e

# Build configuration
APP_NAME="OMI"
BUNDLE_ID="com.omi.focusmonitor"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build release binary
swift build -c release

# Get the built binary path
BINARY_PATH=$(swift build -c release --show-bin-path)/$APP_NAME

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi

echo "Binary built at: $BINARY_PATH"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp Hartford/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Update Info.plist with actual values
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Copy .env file if it exists
if [ -f "../.env" ]; then
    cp "../.env" "$APP_BUNDLE/Contents/Resources/.env"
    echo "Copied .env file to bundle"
elif [ -f ".env" ]; then
    cp ".env" "$APP_BUNDLE/Contents/Resources/.env"
    echo "Copied .env file to bundle"
else
    echo "Warning: No .env file found. Make sure GEMINI_API_KEY is set."
fi

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "Or copy to Applications:"
echo "  cp -r $APP_BUNDLE /Applications/"
