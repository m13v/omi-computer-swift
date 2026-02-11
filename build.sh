#!/bin/bash
set -e

# Build configuration
BINARY_NAME="Omi Computer"  # Package.swift target — binary paths, CFBundleExecutable
APP_NAME="Omi Beta"
BUNDLE_ID="com.omi.computer-macos"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build release binary
swift build -c release --package-path Desktop

# Get the built binary path
BINARY_PATH=$(swift build -c release --package-path Desktop --show-bin-path)/$BINARY_NAME

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi

echo "Binary built at: $BINARY_PATH"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

# Copy Info.plist
cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
cp omi_icon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Update Info.plist with actual values
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Copy resource bundle (contains app assets like herologo.png, omi-with-rope-no-padding.webp, etc.)
SWIFT_BUILD_DIR=$(swift build -c release --package-path Desktop --show-bin-path)
if [ -d "$SWIFT_BUILD_DIR/Omi Computer_Omi Computer.bundle" ]; then
    cp -R "$SWIFT_BUILD_DIR/Omi Computer_Omi Computer.bundle" "$APP_BUNDLE/Contents/Resources/"
    echo "Copied resource bundle"
else
    echo "Warning: Resource bundle not found at $SWIFT_BUILD_DIR/Omi Computer_Omi Computer.bundle"
fi

# Bundle agent-service
echo "Bundling agent service..."
mkdir -p "$APP_BUNDLE/Contents/Resources/agent-service"
cp agent-service/index.js "$APP_BUNDLE/Contents/Resources/agent-service/"
cp agent-service/package.json "$APP_BUNDLE/Contents/Resources/agent-service/"

# Install production dependencies using bundled Node.js
if [ -f "$APP_BUNDLE/Contents/Resources/Omi Computer_Omi Computer.bundle/node" ]; then
    echo "Installing agent service dependencies..."
    cd "$APP_BUNDLE/Contents/Resources/agent-service"
    # Install npm first (it's not bundled with just the node binary)
    # For now, use system npm - we'll need to bundle npm or use a different approach
    npm install --production
    cd - > /dev/null
    echo "Agent service dependencies installed"
else
    echo "Warning: Node.js binary not found in bundle. Agent service will not work."
fi

# Embed API key in release .env
if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" > "$APP_BUNDLE/Contents/Resources/agent-service/.env"
    echo "AGENT_SERVICE_PORT=8081" >> "$APP_BUNDLE/Contents/Resources/agent-service/.env"
    echo "Embedded Anthropic API key in agent service .env"
else
    echo "Warning: ANTHROPIC_API_KEY not set. Agent service will not work in release build."
fi

# Copy .env.app file (app runtime secrets only)
if [ -f ".env.app" ]; then
    cp ".env.app" "$APP_BUNDLE/Contents/Resources/.env"
    echo "Copied .env.app to bundle"
else
    echo "Warning: No .env.app file found. App may not have required API keys."
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
