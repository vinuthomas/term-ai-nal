#!/bin/bash
# Assembles a launchable .app bundle around the SPM executable.
#
# SPM only produces a bare binary. AppKit needs a real bundle (Info.plist,
# CFBundleIdentifier) for the menu bar, window activation and Keychain access
# to behave, so the bundle is built by hand here. This replaces
# electron-builder for the native target.
set -euo pipefail

CONFIG="${1:-debug}"
cd "$(dirname "$0")/.."

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/TermAInal"
APP="build/TermAInal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TermAInal"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>term-ai-nal</string>
    <key>CFBundleDisplayName</key><string>term-ai-nal</string>
    <key>CFBundleIdentifier</key><string>com.termainal.app</string>
    <key>CFBundleExecutable</key><string>TermAInal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0-dev</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature is enough for local runs and lets the Keychain item stick to
# a stable identity. NOT sandboxed: SwiftTerm's child shell needs full access.
codesign --force --sign - "$APP" >/dev/null 2>&1 || \
    echo "    (codesign skipped; app will still run locally)"

echo "==> built $APP"
echo "    run: open $APP     (or $APP/Contents/MacOS/TermAInal for stdout)"
