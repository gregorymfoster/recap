#!/bin/bash
# Build the Recap Dev variant (Debug config → com.gregfoster.recap.dev) and
# install it to /Applications so it launches like a normal app.
#
# Signed with the default Automatic (Apple Development) identity on purpose:
# unsigned binaries won't launch on Apple Silicon, and a stable signature
# keeps the dev app's TCC permission grants across rebuilds instead of
# re-prompting after every install.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen
xcodebuild build -project Recap.xcodeproj -scheme Recap -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dev | tail -2

APP="build/dev/Build/Products/Debug/Recap Dev.app"
DEST="/Applications/Recap Dev.app"

# Quit a running copy so the bundle swap is clean.
osascript -e 'quit app "Recap Dev"' 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Installed $DEST"
echo "  bundle id: $(defaults read "$DEST/Contents/Info" CFBundleIdentifier)"
echo "  version:   $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString)"
