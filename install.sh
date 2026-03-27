#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeMonitor"
SCHEME="ClaudeMonitor"
CONFIGURATION="Release"
INSTALL_DIR="/Applications"
DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData"

echo "Building $APP_NAME ($CONFIGURATION)..."
xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet

BUILD_DIR=$(find "$DERIVED_DATA_DIR" -maxdepth 1 -name "${APP_NAME}-*" -type d -print0 | xargs -0 ls -dt | head -1)
APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: Build product not found at $APP_PATH" >&2
  exit 1
fi

echo "Installing to $INSTALL_DIR/$APP_NAME.app..."
sudo rm -rf "$INSTALL_DIR/$APP_NAME.app"
sudo cp -R "$APP_PATH" "$INSTALL_DIR/"

echo "Done. $APP_NAME installed to $INSTALL_DIR/$APP_NAME.app"
