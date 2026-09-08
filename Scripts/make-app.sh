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
APP="build/term-ai-nal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TermAInal"

# --- Bundled fonts ---
# Registered by macOS at launch via ATSApplicationFontsPath (see Info.plist),
# so the default font is right on a machine with no Nerd Font installed. No
# system-wide installation happens.
if [ -d Resources/Fonts ]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
    cp Resources/Fonts/OFL.txt Resources/Fonts/NOTICE.md "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
fi

# --- License ---
# Surfaced by the Help menu's "Reveal Notices in Finder".
cp LICENSE "$APP/Contents/Resources/LICENSE.txt" 2>/dev/null || true

# --- App icon ---
# Generates a full iconset from Resources/AppIcon.png (1024x1024), cached and
# rebuilt only when the source changes. electron-builder used to do this step;
# nothing does it now, so the bundle would otherwise get the generic icon.
ICON_SRC="Resources/AppIcon.png"
ICON_OUT="build/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    if [ ! -f "$ICON_OUT" ] || [ "$ICON_SRC" -nt "$ICON_OUT" ]; then
        echo "==> generating app icon"
        ICONSET="$(mktemp -d)/AppIcon.iconset"
        mkdir -p "$ICONSET"
        while read -r px name; do
            [ -z "$px" ] && continue
            sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/icon_$name.png" >/dev/null 2>&1
        done <<'SIZES'
16 16x16
32 16x16@2x
32 32x32
64 32x32@2x
128 128x128
256 128x128@2x
256 256x256
512 256x256@2x
512 512x512
1024 512x512@2x
SIZES
        iconutil -c icns "$ICONSET" -o "$ICON_OUT"
    fi
    cp "$ICON_OUT" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (no $ICON_SRC; app will use the generic icon)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>term-ai-nal</string>
    <key>CFBundleDisplayName</key><string>term-ai-nal</string>
    <key>CFBundleIdentifier</key><string>com.termainal.app</string>
    <key>CFBundleExecutable</key><string>TermAInal</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
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

# The Dock and Finder cache icons per bundle path, so a rebuild in place can
# keep showing the previous (or generic) icon until the bundle's mtime moves.
touch "$APP"

echo "==> built $APP"
echo "    run: open $APP     (or $APP/Contents/MacOS/TermAInal for stdout)"
