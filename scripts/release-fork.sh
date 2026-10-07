#!/bin/bash
#
# Builds, signs and publishes a release of this fork (kvnshroom/YTM-Swift)
# with its own Sparkle feed: the app's SUFeedURL points at the appcast.xml of
# the latest GitHub release, so each release ships its own appcast.
#
# Usage:  scripts/release-fork.sh [release-notes.md]
#   Version and build number come from MARKETING_VERSION / CURRENT_PROJECT_VERSION
#   (bump them first). Needs `gh` signed in and the Sparkle EdDSA private key
#   (base64 Ed25519 seed) at $SPARKLE_KEY, default ~/.ssh/ytm-swift-sparkle-ed25519.key.
#   The key must match SUPublicEDKey in Info.plist; never commit it.
#
# The app is signed ad hoc (no Developer ID), so macOS asks for confirmation on
# the first launch after downloading.

set -euo pipefail

REPO=kvnshroom/YTM-Swift
BRANCH=local/kvn
KEY=${SPARKLE_KEY:-$HOME/.ssh/ytm-swift-sparkle-ed25519.key}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOTES=${1:-}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[[ -r $KEY ]] || {
  echo "error: Sparkle key not found at $KEY" >&2
  exit 1
}
[[ -z $(git -C "$ROOT" status --porcelain --untracked-files=no) ]] || {
  echo "error: commit your changes first" >&2
  exit 1
}

echo "Building…"
xcodebuild -project "$ROOT/YT Music.xcodeproj" -scheme "YouTube Music" -configuration Release \
  -derivedDataPath "$WORK/dd" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build -quiet
APP="$WORK/dd/Build/Products/Release/YouTube Music.app"
# One ad hoc identity for the app and its embedded frameworks (Sparkle ships
# team-signed; mixed identities fail library validation at launch).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
TAG="v$VERSION-kvn"
ZIP_NAME="YouTube Music $VERSION.zip"
ZIP="$WORK/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SIGN_UPDATE=$(find "$WORK/dd/SourcePackages/artifacts" -path "*/bin/sign_update" -not -path "*old_dsa*" | head -1)
SIGNATURE=$("$SIGN_UPDATE" --ed-key-file "$KEY" -p "$ZIP")
"$SIGN_UPDATE" --verify --ed-key-file "$KEY" "$ZIP" "$SIGNATURE" >/dev/null
LENGTH=$(stat -f%z "$ZIP")
ZIP_URL="https://github.com/$REPO/releases/download/$TAG/${ZIP_NAME// /%20}"

cat >"$WORK/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>YouTube Music (kvnshroom fork)</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$(LC_ALL=C date -R)</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <enclosure url="$ZIP_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
    </channel>
</rss>
XML

echo "Publishing $TAG ($VERSION, build $BUILD)…"
NOTES_ARGS=(--generate-notes)
[[ -n $NOTES ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "$TAG" "$ZIP" "$WORK/appcast.xml" --repo "$REPO" --target "$BRANCH" \
  --title "YouTube Music $VERSION (fork)" "${NOTES_ARGS[@]}"
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
