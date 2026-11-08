#!/bin/bash
# Builds two separate, clearly labelled TunerX apps:
#   build/TunerX-arm64.app   – Apple Silicon (M-series)
#   build/TunerX-x86_64.app  – Intel
# plus a .zip of each for distribution.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
mkdir -p "$OUT"

for ARCH in arm64 x86_64; do
    case "$ARCH" in
        arm64)  LABEL="Apple Silicon" ;;
        x86_64) LABEL="Intel" ;;
    esac
    echo "==> Building TunerX for $ARCH ($LABEL)"
    SCRATCH=".build-$ARCH"
    swift build -c release --arch "$ARCH" --scratch-path "$SCRATCH"
    BIN="$(swift build -c release --arch "$ARCH" --scratch-path "$SCRATCH" --show-bin-path)/TunerX"

    APP="$OUT/TunerX-$ARCH.app"
    rm -rf "$APP" "$OUT/TunerX-$ARCH.zip"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/TunerX"
    cp Resources/Info.plist "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName TunerX ($LABEL)" "$APP/Contents/Info.plist"
    if [ -f Resources/AppIcon.icns ]; then
        cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    fi
    codesign --force --options runtime --entitlements Resources/TunerX.entitlements --sign - "$APP"

    GOT="$(lipo -archs "$APP/Contents/MacOS/TunerX")"
    if [ "$GOT" != "$ARCH" ]; then echo "ERROR: $APP contains '$GOT', expected '$ARCH'"; exit 1; fi
    ditto -c -k --keepParent "$APP" "$OUT/TunerX-$ARCH.zip"
    echo "    $APP  [$GOT]"
done

echo
echo "Done:"
for ARCH in arm64 x86_64; do
    printf '  %-28s %s\n' "build/TunerX-$ARCH.app" "$(file -b "$OUT/TunerX-$ARCH.app/Contents/MacOS/TunerX")"
done
