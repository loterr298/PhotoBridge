#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift build -c release --arch x86_64 --product PhotoBridgeMac
BIN_DIR=$(swift build -c release --arch x86_64 --show-bin-path)
APP=build/PhotoBridgeMac.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PhotoBridgeMac" "$APP/Contents/MacOS/PhotoBridgeMac"
cp apps/macOS/Info.plist "$APP/Contents/Info.plist"
cp apps/macOS/PhotoBridge.icns "$APP/Contents/Resources/PhotoBridge.icns"
mkdir -p "$APP/Contents/Resources/scripts"
cp scripts/*.py scripts/*.sh "$APP/Contents/Resources/scripts/"
codesign --force --sign - "$APP"
lipo -info "$APP/Contents/MacOS/PhotoBridgeMac"
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" build/PhotoBridgeMac-Intel.zip
shasum -a 256 build/PhotoBridgeMac-Intel.zip
