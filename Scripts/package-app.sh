#!/usr/bin/env bash
# Wrap the SwiftPM-built LociiGhost executable in a minimal .app bundle so
# macOS treats it as a real GUI app (dock icon, focusable window, Cmd-Q).
#
# Phase 1: ad-hoc signing only. No notarisation. No Sparkle. The DMG and
# distribution-grade signing pipeline lands in Phase 5.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP_DIR="$ROOT/App"

CONFIG=${CONFIG:-debug}
BUILD_SUBDIR=$([ "$CONFIG" = "release" ] && echo arm64-apple-macosx/release || echo arm64-apple-macosx/debug)
BIN_DIR="$APP_DIR/.build/$BUILD_SUBDIR"
BIN="$BIN_DIR/LociiGhost"
RESOURCE_BUNDLE="$BIN_DIR/LociiGhost_LociiGhost.bundle"

# Always invoke `swift build` so source edits actually make it into the
# packaged app. The earlier `[[ ! -x "$BIN" ]]` gate silently reused the
# previous SwiftPM artifact whenever the binary already existed -- so
# every iteration of "edit source -> rebuild -> test" was actually
# testing the *previous* binary. SwiftPM is incremental and fast on
# no-ops, so dropping the gate isn't a real cost.
echo "==> building LociiGhost ($CONFIG)"
(cd "$APP_DIR" && swift build --product LociiGhost --configuration "$CONFIG")

OUT="$ROOT/dist/LociiGhost.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BIN" "$OUT/Contents/MacOS/LociiGhost"
chmod +x "$OUT/Contents/MacOS/LociiGhost"

# SwiftPM's resource bundle has to live next to the executable so that
# Bundle.module resolves at runtime.
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$OUT/Contents/MacOS/"
fi

cat >"$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>LociiGhost</string>
    <key>CFBundleIdentifier</key>
    <string>com.lociighost.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>LociiGhost</string>
    <key>CFBundleDisplayName</key>
    <string>LociiGhost</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSLocationUsageDescription</key>
    <string>LociiGhost shows your Mac's location on the map as an approximation of your iPhone's real GPS. Apple does not allow connected iPhones to share GPS over USB, so the Mac's position is the closest stand-in.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>LociiGhost shows your Mac's location on the map as an approximation of your iPhone's real GPS. Apple does not allow connected iPhones to share GPS over USB, so the Mac's position is the closest stand-in.</string>
</dict>
</plist>
PLIST

printf 'APPL????' >"$OUT/Contents/PkgInfo"

# Ad-hoc sign so Gatekeeper at least understands what this is.
codesign --sign - --force --deep --options runtime "$OUT" 2>/dev/null || true

echo "==> packaged: $OUT"
echo "==> open with: open $OUT"
