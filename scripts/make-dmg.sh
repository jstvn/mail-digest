#!/bin/bash
# Builds a universal (Apple silicon + Intel) Release of MailDigest.app and packages it as a
# drag-to-Applications disk image, plus a SHA-256 checksum for the release notes.
#
# Signing uses the project's settings. For a public release, sign with a Developer ID
# Application certificate so users keep their Full Disk Access and Automation grants across updates:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/make-dmg.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/MailDigestApp/MailDigest.xcodeproj"
WORK="$REPO_ROOT/.build/dmg"
DERIVED="$WORK/DerivedData"
STAGING="$WORK/staging"
OUT_DIR="$REPO_ROOT/.build/release"

sign_args=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign_args=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual)
fi

rm -rf "$WORK"
xcodebuild -project "$PROJECT" -scheme MailDigest -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  ${sign_args[@]+"${sign_args[@]}"} \
  build

APP="$DERIVED/Build/Products/Release/MailDigest.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT_DIR/MailDigest-$VERSION.dmg"

# The Applications symlink gives Finder the familiar drag-to-install layout.
mkdir -p "$STAGING" "$OUT_DIR"
ditto "$APP" "$STAGING/MailDigest.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Mail Digest" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/MailDigest")"
echo "Disk image:    $DMG"
cat "$DMG.sha256"
