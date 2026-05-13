#!/usr/bin/env bash
# Build a Developer-ID-signed + notarised + stapled .dmg from an
# already-signed-and-stapled .app. Output: dist/LociiGhost-vX.Y.Z.dmg
#
# Usage:
#   ./Scripts/make-dmg.sh /path/to/LociiGhost.app
#
# Env vars (same as package-app.sh):
#   LOCIIGHOST_SIGN_IDENTITY  — Developer ID Application: ... (required)
#   LOCIIGHOST_NOTARY_PROFILE — notarytool keychain profile (required for
#                                full release; sign-only if absent)
#
# The DMG holds just two items at the root:
#   1. LociiGhost.app
#   2. Applications  → /Applications  (symlink for the classic
#                                      "drag the app to the right" UX)
#
# No fancy background image / icon positions yet — that's a Finder
# AppleScript layer that's worth its own iteration. The plain DMG
# already looks markedly more "real software" than a .zip and works
# everywhere.

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "usage: $0 /path/to/LociiGhost.app" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

# Read CFBundleShortVersionString so the DMG filename embeds the
# version the user will actually see in About / Finder Get Info.
VERSION="$(plutil -extract CFBundleShortVersionString raw \
    "$APP/Contents/Info.plist")"
DMG="$DIST/LociiGhost-v$VERSION.dmg"

SIGN_IDENTITY="${LOCIIGHOST_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${LOCIIGHOST_NOTARY_PROFILE:-}"

# Stage everything outside ~/Documents — same File Provider xattr
# minefield as package-app.sh. /tmp isn't watched by iCloud Drive
# and hdiutil happily reads from it.
STAGE_DIR="$(mktemp -d)"
STAGE="$STAGE_DIR/dmg-root"
mkdir -p "$STAGE"

# ditto copies content only (no xattrs / ACLs / resource forks); the
# .app's existing code signature survives intact, but the iCloud
# File Provider metadata does not follow into /tmp.
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/$(basename "$APP")"

# Drag-target symlink. Finder shows it as "Applications" with the
# standard folder icon; clicking through it lands in /Applications.
ln -s /Applications "$STAGE/Applications"

# Build, sign, notarise, and staple the DMG entirely under /tmp.
# Same File Provider gotcha as package-app.sh: if the DMG sits in
# ~/Documents/LociiGhost/dist/ during sign/staple, iCloud Drive can
# re-attach `com.apple.fileprovider.fpfs#P` between steps and break
# codesign mid-flight. Only the final stapled DMG moves into dist/.
TMP_DMG="$STAGE_DIR/$(basename "$DMG")"

echo "==> building DMG (volume name: LociiGhost)"
# UDZO = compressed read-only; the standard format for shipping
# Mac apps. -ov overwrites any existing dmg with the same name.
hdiutil create \
    -volname "LociiGhost" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -o "$TMP_DMG" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> signing DMG: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$TMP_DMG"
    codesign --verify --verbose=2 "$TMP_DMG"
fi

if [[ -n "$SIGN_IDENTITY" && -n "$NOTARY_PROFILE" ]]; then
    echo "==> notarising DMG via keychain profile: $NOTARY_PROFILE"
    xcrun notarytool submit "$TMP_DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        | tee "$DIST/notarytool-dmg.log"

    echo "==> stapling notarisation ticket to DMG"
    xcrun stapler staple "$TMP_DMG"

    echo "==> post-staple Gatekeeper check"
    # `--type install` because we're verifying a DMG, not an .app.
    spctl --assess --type install --verbose "$TMP_DMG" 2>&1 \
        | sed 's/^/    /' || true

    echo "==> DMG notarised + stapled"
elif [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> DMG signed (no notary profile — local-only)"
else
    echo "==> DMG built (unsigned — for local testing only)"
fi

# Move the finished DMG into dist/ at the very end. By this point
# the DMG already has its notarisation ticket stapled inside, so any
# xattrs iCloud attaches afterwards don't affect Gatekeeper.
rm -f "$DMG"
mv "$TMP_DMG" "$DMG"
rm -rf "$STAGE_DIR"

# Quick size summary for the user.
ls -lh "$DMG" | awk '{print "==> size: " $5}'
