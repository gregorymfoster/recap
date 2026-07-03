#!/bin/bash
# Cut a Recap release: archive → Developer ID sign → notarize → staple →
# DMG → Sparkle appcast → draft GitHub release.
#
# Usage: Scripts/release.sh <version>   e.g. Scripts/release.sh 0.1.0
#
# One-time setup (done once per machine):
#   1. A "Developer ID Application" certificate in the login keychain.
#      Only the Apple Developer Account Holder can create one:
#      https://developer.apple.com/account/resources/certificates/add
#      (choose "Developer ID Application", or Xcode → Settings → Accounts →
#      Manage Certificates → + → Developer ID Application).
#   2. App Store Connect API key at ~/.appstoreconnect/private_keys/ (present).
#   3. Sparkle EdDSA keys in the login keychain (created; public key is in
#      project.yml). Sparkle tools come from `brew install --cask sparkle` or
#      the Sparkle release tarball — set SPARKLE_BIN to their directory.
#   4. brew install xcodegen create-dmg; gh auth login.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version>}"
TEAM_ID="2V7W69N399"
ASC_KEY_ID="XS4DNNPK82"
ASC_ISSUER="69a6de74-5cd4-47e3-e053-5b8c7c11a4d1"
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
SPARKLE_BIN="${SPARKLE_BIN:-}"
BUILD_DIR="build"
DMG="dist/Recap-$VERSION.dmg"

command -v xcodegen >/dev/null || { echo "missing: brew install xcodegen" >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "missing: brew install create-dmg" >&2; exit 1; }
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No 'Developer ID Application' certificate in the keychain." >&2
  echo "Create one (Account Holder only): https://developer.apple.com/account/resources/certificates/add" >&2
  exit 1
fi
if [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Set SPARKLE_BIN to Sparkle's bin/ directory (contains generate_appcast, sign_update)." >&2
  exit 1
fi
if [[ ! -f "$ASC_KEY_PATH" ]]; then
  echo "Missing App Store Connect API key at $ASC_KEY_PATH" >&2
  exit 1
fi

echo "==> Version $VERSION"
/usr/bin/sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
/usr/bin/sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
/usr/bin/sed -i '' "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$BUILD_NUMBER\"/" project.yml
xcodegen

echo "==> Archive"
rm -rf "$BUILD_DIR" dist && mkdir -p dist
xcodebuild archive \
  -project Recap.xcodeproj -scheme Recap -configuration Release \
  -archivePath "$BUILD_DIR/Recap.xcarchive" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" | tail -3

APP="$BUILD_DIR/Recap.xcarchive/Products/Applications/Recap.app"

echo "==> Re-sign Sparkle's nested helpers"
# Sparkle.framework ships its own helper binaries pre-signed adhoc (no team
# identity, no secure timestamp) — `xcodebuild archive` doesn't re-sign
# already-signed nested code, so notarization rejects them. Sign deepest-first
# per Sparkle's notarization guide, then re-sign the framework and outer app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
sign() {
  codesign --force --options runtime --timestamp --sign "Developer ID Application" "$1"
}
if [[ -d "$SPARKLE_FW" ]]; then
  sign "$SPARKLE_FW/Versions/B/Autoupdate"
  sign "$SPARKLE_FW/Versions/B/Updater.app/Contents/MacOS/Updater"
  sign "$SPARKLE_FW/Versions/B/Updater.app"
  sign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  sign "$SPARKLE_FW"
fi
sign "$APP"

echo "==> Notarize"
/usr/bin/ditto -c -k --keepParent "$APP" "$BUILD_DIR/Recap.zip"
xcrun notarytool submit "$BUILD_DIR/Recap.zip" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
xcrun stapler staple "$APP"

echo "==> DMG"
create-dmg \
  --volname "Recap" \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "Recap.app" 140 180 \
  --app-drop-link 400 180 \
  --hide-extension "Recap.app" \
  "$DMG" "$APP"
xcrun notarytool submit "$DMG" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
xcrun stapler staple "$DMG"

echo "==> GitHub release"
# Publish the release BEFORE pushing the appcast: the appcast goes live the
# moment it lands on GitHub Pages, and a draft release's assets 404 publicly —
# every installed app would hit "Update Error!" until the draft is published.
git add project.yml Recap/Info.plist
git commit -m "Release v$VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$DMG" --title "Recap $VERSION" --generate-notes

echo "==> Verify download URL"
DOWNLOAD_URL="https://github.com/gregorymfoster/recap/releases/download/v$VERSION/Recap-$VERSION.dmg"
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -L -r 0-0 "$DOWNLOAD_URL")
  [[ "$CODE" == 200 || "$CODE" == 206 ]] && break
  echo "  $DOWNLOAD_URL -> $CODE, retrying ($i/30)…"
  sleep 10
done
if [[ "$CODE" != 200 && "$CODE" != 206 ]]; then
  echo "Release asset never became downloadable ($CODE); NOT publishing appcast." >&2
  exit 1
fi

echo "==> Appcast"
"$SPARKLE_BIN/generate_appcast" dist/ --download-url-prefix \
  "https://github.com/gregorymfoster/recap/releases/download/v$VERSION/"
cp dist/appcast.xml docs/appcast.xml
git add docs/appcast.xml
git commit -m "Publish appcast for v$VERSION"
git push origin main

echo
echo "Release v$VERSION published; appcast is live."
