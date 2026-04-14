#!/bin/bash
set -e

./build.sh

BUILD_DIR=$(xcodebuild -project UnnamedWindowManager.xcodeproj -scheme UnnamedWindowManager -showBuildSettings 2>/dev/null | grep -m 1 'BUILT_PRODUCTS_DIR' | sed 's/.*= //')
APP_PATH="$BUILD_DIR/UnnamedWindowManager.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found"
  exit 1
fi

cp -R "$APP_PATH" /Applications/
echo "Installed UnnamedWindowManager.app to /Applications/"
