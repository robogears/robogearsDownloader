#!/bin/bash
# Builds the release artifacts for robogears Downloader into macos/dist/.
# It never publishes anything; cutting the GitHub release is the github-ship
# skill's job.
#
#   robogears-downloader-mac-arm64.dmg         people installing for the first time,
#                                              AND the v0.1.30 Electron updater: it looks
#                                              for an asset whose name contains
#                                              "mac-arm64.dmg" and installs the first
#                                              .app at the disk image's root.
#   robogears-downloader-mac-arm64.zip         the Swift app's own updater (ditto zip).
#   <asset>.sha256                             "<hex>  <name>", checked before staging.
#
# Change these names only together with UpdateAssets.matchAsset (Swift) — they
# are one contract split across two places.
#
# Signing: ad hoc by default. Once a code-signing certificate exists, pass its
# name: SIGN_IDENTITY="robogears Code Signing" macos/scripts/package-release.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # macos/
APP_NAME="robogears Downloader"
DMG_NAME="robogears-downloader-mac-arm64.dmg"
ZIP_NAME="robogears-downloader-mac-arm64.zip"
IDENTITY="${SIGN_IDENTITY:--}"
DERIVED="$HERE/build/DerivedData"
DIST="$HERE/dist"

cd "$HERE"
echo "==> Generating the Xcode project"
xcodegen generate --quiet

echo "==> Building Release"
xcodebuild -project RobogearsDownloader.xcodeproj -scheme RobogearsDownloader \
  -configuration Release -derivedDataPath "$DERIVED" build -quiet

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: $APP was not built" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "    version $VERSION"

echo "==> Signing ($IDENTITY)"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Zip for the in-app updater"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP_NAME"

echo "==> Disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Install $APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$DMG_NAME"

echo "==> Checksums"
(cd "$DIST" && for f in "$ZIP_NAME" "$DMG_NAME"; do shasum -a 256 "$f" > "$f.sha256"; done)

echo
echo "Built $VERSION in $DIST:"
ls -lh "$DIST"
echo
echo "Next: cut a draft release with all four files (github-ship). The tag must be"
echo "v$VERSION, numerically above v0.1.30, so v0.1.30 Electron users are offered it."
