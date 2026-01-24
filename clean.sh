#!/bin/bash
# Full cleanup script - removes app and all permissions/data

BUNDLE_ID="com.omi.focusmonitor"
APP_PATH="/Applications/OMI.app"
BUILD_PATH="build/OMI.app"

echo "=== Full OMI Cleanup ==="

# Kill the app if running
echo "Killing app..."
pkill -9 OMI 2>/dev/null || true

# Remove app from Applications
if [ -d "$APP_PATH" ]; then
    echo "Removing $APP_PATH..."
    rm -rf "$APP_PATH"
fi

# Remove from build folder
if [ -d "$BUILD_PATH" ]; then
    echo "Removing $BUILD_PATH..."
    rm -rf "$BUILD_PATH"
fi

# Reset all TCC permissions (works fully once app is removed)
echo "Resetting all TCC permissions..."
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true

# Delete user defaults
echo "Deleting user defaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true

# Clean up Library folders
echo "Cleaning Library folders..."
rm -rf ~/Library/Application\ Support/"$BUNDLE_ID" 2>/dev/null || true
rm -rf ~/Library/Caches/"$BUNDLE_ID" 2>/dev/null || true
rm -rf ~/Library/Preferences/"$BUNDLE_ID".plist 2>/dev/null || true

# Kill System Settings and tccd to force refresh
echo "Restarting system services..."
killall "System Settings" 2>/dev/null || true
killall tccd 2>/dev/null || true

echo ""
echo "=== Cleanup complete ==="
echo "Note: Notification permissions must be reset manually in System Settings"
