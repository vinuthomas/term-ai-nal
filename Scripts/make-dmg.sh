#!/bin/bash
# Packages build/term-ai-nal.app (from Scripts/make-app.sh) into a distributable
# DMG: the app plus an /Applications symlink, the standard drag-install layout.
#
# No Developer ID or notarization exists on this machine yet (see CLAUDE.md
# Known Gaps) — the app inside is only ad-hoc signed, so Gatekeeper will warn
# "unidentified developer" on another Mac. Right-click > Open (or
# `xattr -cr term-ai-nal.app`) bypasses it; there is no way to suppress the
# warning itself without a real signing identity and `notarytool`.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/term-ai-nal.app"
[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/make-app.sh release first" >&2; exit 1; }

VERSION="$(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString)"
ARCH="$(uname -m)"
DMG="build/term-ai-nal-$VERSION-$ARCH.dmg"

STAGING="$(mktemp -d)/term-ai-nal"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "term-ai-nal $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "==> built $DMG"
