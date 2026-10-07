#!/bin/bash
#
# Installs or updates the latest release of this fork (kvnshroom/YTM-Swift)
# in /Applications for the current user.
#
# Usage:  scripts/install-fork.sh
#    or:  curl -fsSL https://raw.githubusercontent.com/kvnshroom/YTM-Swift/local/kvn/scripts/install-fork.sh | bash
#
# The release comes from the fork's Sparkle feed. The app is signed ad hoc, so
# the download quarantine is removed to skip the "unidentified developer"
# prompt. A previously installed copy is moved to the Trash.
# INSTALL_DIR overrides the destination, NO_OPEN=1 skips launching.

set -euo pipefail

REPO=kvnshroom/YTM-Swift
APP="YouTube Music.app"
BUNDLE_ID=moe.tenshii.YT-Music
DEST=${INSTALL_DIR:-/Applications}
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Looking up the latest release…"
URL=$(curl -fsSL "$FEED" | sed -n 's/.*url="\([^"]*\)".*/\1/p' | head -1)
VERSION=$(curl -fsSL "$FEED" | sed -n 's/.*<sparkle:shortVersionString>\(.*\)<\/sparkle:shortVersionString>.*/\1/p' | head -1)
if [[ -z $URL ]]; then
  echo "error: no download found in $FEED" >&2
  exit 1
fi

echo "Downloading YouTube Music ${VERSION}…"
curl -fL --progress-bar -o "$WORK/app.zip" "$URL"
ditto -x -k "$WORK/app.zip" "$WORK/unpacked"
if [[ ! -d "$WORK/unpacked/$APP" ]]; then
  echo "error: the download doesn't contain $APP" >&2
  exit 1
fi
codesign --verify --deep --strict "$WORK/unpacked/$APP"

if pgrep -xu "$(id -u)" "YouTube Music" >/dev/null; then
  echo "Quitting the running app…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -xu "$(id -u)" "YouTube Music" >/dev/null || break
    sleep 0.5
  done
fi

if [[ -d "$DEST/$APP" ]]; then
  echo "Moving the old version to the Trash…"
  mv "$DEST/$APP" "$HOME/.Trash/YouTube Music (replaced $(date +%Y-%m-%d_%H%M%S)).app"
fi
ditto "$WORK/unpacked/$APP" "$DEST/$APP"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "Installed YouTube Music $VERSION in $DEST."
if [[ ${NO_OPEN:-0} != 1 ]]; then
  open "$DEST/$APP"
fi
