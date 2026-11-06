#!/bin/bash
# Builds TunerX.app (release, ad-hoc signed) into ./build
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TunerX"

APP="build/TunerX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TunerX"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Resources/TunerX.entitlements --sign - "$APP"

echo "Built $APP"
echo "Run:   open $APP"
