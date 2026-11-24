#!/bin/sh
# Builds a release Scribe.app into ./build. Pass --install to also copy it to /Applications.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product Scribe

APP=build/Scribe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Scribe" "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/Scribe.app
    cp -R "$APP" /Applications/Scribe.app
    echo "Installed /Applications/Scribe.app"
fi
