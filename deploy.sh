#!/bin/bash
# Flote deploy script: build Release and update /Applications
set -e

echo "Building Flote (Release)..."
xcodebuild -project apps/macos/Flote.xcodeproj -scheme Flote -configuration Release build -quiet

echo "Stopping running Flote..."
pkill -f "Flote.app" 2>/dev/null || true
sleep 1

echo "Deploying to /Applications..."
rm -rf /Applications/Flote.app
cp -R ~/Library/Developer/Xcode/DerivedData/Flote-*/Build/Products/Release/Flote.app /Applications/

# Remove DerivedData copies to prevent duplicate Launchpad entries
rm -rf ~/Library/Developer/Xcode/DerivedData/Flote-*/Build/Products/Debug/Flote.app 2>/dev/null
rm -rf ~/Library/Developer/Xcode/DerivedData/Flote-*/Build/Products/Release/Flote.app 2>/dev/null

echo "Launching Flote..."
open /Applications/Flote.app

echo "Done."
