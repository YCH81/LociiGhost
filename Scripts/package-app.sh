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

# Copy *.lproj directories from the SOURCE tree (not the SwiftPM-
# processed bundle, which lowercases the lproj directory names — and
# `Locale(identifier: "zh-Hant")` lookups want the canonical
# camel-cased "zh-Hant.lproj"). Going straight from source avoids
# the lowercase rewrite. We put them into Contents/Resources/ so
# `Bundle.main`'s default lookup picks them up — SwiftUI Text(...)
# uses Bundle.main, not Bundle.module, by default.
SOURCE_RES="$APP_DIR/Sources/LociiGhost/Resources"
for lproj in "$SOURCE_RES"/*.lproj; do
    if [[ -d "$lproj" ]]; then
        cp -R "$lproj" "$OUT/Contents/Resources/"
    fi
done

# App icon. The .icns is produced by Scripts/generate-icon.swift
# from the master design at Resources/AppIcon-Master.pdf. If it's
# missing, regenerate it on the fly so a fresh checkout still
# produces an iconified .app without needing two scripts in order.
ICNS_SRC="$SOURCE_RES/AppIcon.icns"
if [[ ! -f "$ICNS_SRC" ]]; then
    echo "==> AppIcon.icns not found — regenerating from master"
    (cd "$ROOT" && swift Scripts/generate-icon.swift)
fi
cp "$ICNS_SRC" "$OUT/Contents/Resources/AppIcon.icns"

cat >"$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hant</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>LociiGhost</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <string>1.10.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 YCH81 (Jeff Hu). Includes LocWarp © 2026 keezxc1223, used under MIT License — see LICENSE for full text.</string>
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

# ── Signing pipeline ──────────────────────────────────────────────
#
# Two modes, selected by environment variables. Defaults (nothing
# set) keep the historical ad-hoc behaviour so day-to-day local
# builds aren't disturbed.
#
#   LOCIIGHOST_SIGN_IDENTITY
#       Full Developer ID Application identity string, e.g.
#         "Developer ID Application: Jeff Hu (ABCDEFGHIJ)"
#       Trigger for Hardened-Runtime + timestamp + entitlements
#       signing. The .app emerging from this path is Gatekeeper-
#       acceptable on someone else's Mac without `xattr -d
#       com.apple.quarantine` gymnastics.
#
#   LOCIIGHOST_NOTARY_PROFILE
#       Name of a `notarytool store-credentials` keychain profile.
#       When BOTH this AND LOCIIGHOST_SIGN_IDENTITY are set, the
#       signed .app is zipped, uploaded to Apple's notarisation
#       service, and the resulting ticket is stapled back onto it.
#       Once stapled, the .app launches on any Mac with full
#       Gatekeeper trust, including offline (the stapled ticket
#       removes the network check).
#
# First-time setup (run once on your dev Mac):
#
#   xcrun notarytool store-credentials LociiGhost \
#       --apple-id you@example.com \
#       --team-id  ABCDEFGHIJ \
#       --password "app-specific-password-from-appleid.apple.com"
#
# Then for every release build:
#
#   export LOCIIGHOST_SIGN_IDENTITY="Developer ID Application: Jeff Hu (ABCDEFGHIJ)"
#   export LOCIIGHOST_NOTARY_PROFILE="LociiGhost"
#   CONFIG=release ./Scripts/package-app.sh

SIGN_IDENTITY="${LOCIIGHOST_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${LOCIIGHOST_NOTARY_PROFILE:-}"
ENTITLEMENTS="$ROOT/Scripts/LociiGhost.entitlements"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Developer ID signing: $SIGN_IDENTITY"

    if [[ ! -f "$ENTITLEMENTS" ]]; then
        echo "    entitlements file missing at $ENTITLEMENTS" >&2
        exit 1
    fi

    # Move the .app entirely outside ~/Documents before any
    # signing step. macOS's File Provider daemon (the iCloud Drive
    # sync engine) keeps re-attaching `com.apple.fileprovider.fpfs#P`
    # — a system-protected extended attribute — to any file we
    # write inside an iCloud-synced directory. codesign rejects
    # files carrying that xattr with "resource fork / Finder
    # information / detritus not allowed". xattr -cr can't strip
    # it (the `#P` suffix marks it protected) and the daemon races
    # us back into the file between sign steps even after ditto.
    #
    # /tmp isn't watched by any File Provider, so all signing /
    # notarisation work happens there cleanly. At the end we ditto
    # the finished .app back to dist/ for the user.
    ORIGINAL_OUT="$OUT"
    SIGN_WORK="$(mktemp -d)"
    OUT="$SIGN_WORK/$(basename "$ORIGINAL_OUT")"
    ditto --norsrc --noextattr --noacl "$ORIGINAL_OUT" "$OUT"
    rm -rf "$ORIGINAL_OUT"

    # Inside-out signing: every nested signable item (SwiftPM
    # resource bundle, main executable) gets signed BEFORE the
    # outer .app wrapper. codesign rejects nested-already-signed
    # contents otherwise, and notarisation rejects unsigned
    # nested binaries.
    if [[ -d "$OUT/Contents/MacOS/LociiGhost_LociiGhost.bundle" ]]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" \
            "$OUT/Contents/MacOS/LociiGhost_LociiGhost.bundle"
    fi

    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$OUT/Contents/MacOS/LociiGhost"

    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$OUT"

    echo "==> verifying signature"
    codesign --verify --deep --strict --verbose=2 "$OUT"
    # spctl is the Gatekeeper assess — pre-notarisation it'll say
    # "rejected: source=Unnotarized Developer ID", which is fine.
    # Post-staple it says "accepted: source=Notarized Developer ID".
    spctl --assess --type execute --verbose "$OUT" 2>&1 \
        | sed 's/^/    /' || true

    if [[ -n "$NOTARY_PROFILE" ]]; then
        echo "==> notarising via keychain profile: $NOTARY_PROFILE"
        ZIP="$ROOT/dist/LociiGhost.zip"
        rm -f "$ZIP"
        # ditto -k produces an Apple-compatible zip that
        # preserves the .app's extended attributes; plain `zip`
        # corrupts code signatures.
        /usr/bin/ditto -c -k --keepParent "$OUT" "$ZIP"

        # --wait blocks until Apple's servers return a verdict
        # (usually under a minute, occasionally up to 30 min if
        # they're backlogged). Pipe through `tee` so the log
        # ends up in stdout for CI.
        xcrun notarytool submit "$ZIP" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait \
            | tee "$ROOT/dist/notarytool.log"

        echo "==> stapling notarisation ticket"
        xcrun stapler staple "$OUT"

        echo "==> post-staple Gatekeeper check"
        spctl --assess --type execute --verbose "$OUT" 2>&1 \
            | sed 's/^/    /' || true

        # Keep the .zip alongside the .app — power users / CI scripts
        # often prefer the smaller zip download over the DMG. We also
        # rename it to be version-stamped so multiple releases can
        # coexist in dist/ without overwriting each other.
        APP_VERSION="$(plutil -extract CFBundleShortVersionString raw \
            "$OUT/Contents/Info.plist")"
        VERSIONED_ZIP="$ROOT/dist/LociiGhost-v${APP_VERSION}.zip"
        mv "$ZIP" "$VERSIONED_ZIP"
        echo "==> notarised + stapled — ready for distribution"
        echo "==> zip:  $VERSIONED_ZIP"

        # Chain into make-dmg.sh so a release build always produces
        # both flavours: zip for the technical crowd, DMG for the
        # "drag-to-Applications" mainstream UX. The DMG gets its own
        # notarisation pass; the .app inside is already stapled so
        # Gatekeeper accepts the .app whether the user copies it
        # from the mounted volume or extracts it via Archive Utility.
        "$ROOT/Scripts/make-dmg.sh" "$OUT"
    else
        echo "==> signed with Developer ID, but no notary profile set"
        echo "    (skipping notarisation — .app will work locally but"
        echo "     show 'unverified developer' on other Macs)"
        echo
        echo "    To enable notarisation:"
        echo "      1) xcrun notarytool store-credentials LociiGhost \\"
        echo "             --apple-id you@example.com \\"
        echo "             --team-id ABCDEFGHIJ \\"
        echo "             --password '<app-specific-password>'"
        echo "      2) export LOCIIGHOST_NOTARY_PROFILE=LociiGhost"
        echo "      3) re-run this script"
    fi

    # Move the finished (signed + notarised + stapled) .app back to
    # its original dist/ location. All signing work happened under
    # /tmp/$SIGN_WORK so iCloud Drive's File Provider couldn't race
    # codesign with re-attached protected xattrs; the user expects
    # the final artefact at the original $OUT path though.
    ditto --norsrc --noextattr --noacl "$OUT" "$ORIGINAL_OUT"
    rm -rf "$SIGN_WORK"
    OUT="$ORIGINAL_OUT"
else
    # Local-development ad-hoc fallback. No certificate needed,
    # but the .app only opens on this Mac (Gatekeeper warns
    # everywhere else).
    echo "==> ad-hoc signing (LOCIIGHOST_SIGN_IDENTITY not set — local-only build)"
    codesign --sign - --force --deep --options runtime "$OUT" 2>/dev/null || true
fi

echo "==> packaged: $OUT"
echo "==> open with: open $OUT"
