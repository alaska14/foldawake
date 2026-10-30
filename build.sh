#!/bin/zsh
# Builds FoldAwake.app from source into ./build/FoldAwake.app
# Requirements: macOS 12+ and Apple's Command Line Tools (run: xcode-select --install)
# Usage: ./build.sh            (then drag build/FoldAwake.app to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

NAME=FoldAwake
BUNDLE_ID=com.foldawake.app
VERSION=1.2.0
SDK=${SDK:-$(xcrun --show-sdk-path)}

APP=build/$NAME.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>$NAME uses System Events to add itself to your Login Items.</string>
</dict>
</plist>
PLIST

clang -O2 -fobjc-arc -Wno-writable-strings -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -isysroot "$SDK" -framework Cocoa -framework IOKit -F/System/Library/PrivateFrameworks -framework DisplayServices \
  $NAME.m -o "$APP/Contents/MacOS/$NAME"
codesign --force --deep --sign - "$APP"
echo "Built $APP ($VERSION)"
