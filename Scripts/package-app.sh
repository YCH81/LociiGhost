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

# Guard: never let `bundle: .module` reach a packaged build. See the
# comment block further down (around the SwiftPM resource bundle
# copy) for the full diagnosis. tl;dr: SwiftPM's executable-target
# accessor only checks the .app root + a hardcoded developer
# `.build/` path, so any `String(localized: …, bundle: .module, …)`
# crashes the .app on launch on every machine except the dev's own.
if grep -rn "bundle: \.module" "$APP_DIR/Sources/LociiGhost" --include="*.swift" 2>/dev/null; then
    echo "❌ bundle: .module is not allowed in this project — it crashes the packaged .app on launch." >&2
    echo "   Use String(localized: \"…\") without a bundle argument." >&2
    exit 1
fi

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

# SwiftPM's auto-generated `Bundle.module` accessor (look in
# .build/.../DerivedSources/resource_bundle_accessor.swift to
# confirm) is unusable for packaged-.app distribution:
#
#   let mainPath = Bundle.main.bundleURL
#       .appendingPathComponent("LociiGhost_LociiGhost.bundle").path
#   let buildPath = "/Users/<dev>/.../App/.build/.../release/
#                    LociiGhost_LociiGhost.bundle"
#
# `Bundle.main.bundleURL` on a packaged .app is the .app itself
# (so it looks at `.app/LociiGhost_LociiGhost.bundle`, NOT
# `.app/Contents/Resources/LociiGhost_LociiGhost.bundle`); the
# `buildPath` fallback hardcodes the developer's local SwiftPM
# directory at compile time. End-user machines have neither
# location, so `Bundle.module`'s `fatalError` fires on first
# access — which is what crashed v1.10.0 / v1.10.1 / v1.10.2 /
# v1.10.3 on every machine except the developer's own.
#
# The fix is upstream of this script: the source guard above
# (`grep -rn "bundle: \.module"`) refuses to package any build
# that still routes a `String(localized:)` through `.module`.
# Without those callsites, the `static let module` lazy initialiser
# never runs and its `fatalError` becomes dead code regardless of
# where the bundle physically lives.
#
# We still copy the bundle into `Contents/Resources/` because
# Bundle.main's default localisation lookup uses
# `Contents/Resources/`-and-friends, and we still want SwiftUI
# `Text("...")` (which goes through Bundle.main, not Bundle.module)
# to find any future bundled assets. That's also the Apple-canonical
# location, so codesign doesn't complain about unsealed contents at
# the .app root.
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$OUT/Contents/Resources/"
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

# Bundled daemon. The PyInstaller `--onedir` output at
# `Daemon/dist/lociighostd/` is a complete self-contained Python
# runtime + lociighostd entry point. We copy the whole directory into
# `.app/Contents/Resources/lociighostd/` so end users who download
# the DMG have a working daemon without needing to clone the repo
# or have Python installed. DaemonLifecycle + PrivilegedDaemonInstaller
# look here first, falling back to the dev-mode staged venv only when
# the bundle isn't present (which happens when building from source
# without first running build-daemon.sh).
DAEMON_DIST="$ROOT/Daemon/dist/lociighostd"
if [[ -d "$DAEMON_DIST" ]]; then
    echo "==> bundling daemon: $DAEMON_DIST → Contents/Resources/lociighostd/"
    ditto --norsrc --noextattr --noacl \
        "$DAEMON_DIST" \
        "$OUT/Contents/Resources/lociighostd"
    chmod +x "$OUT/Contents/Resources/lociighostd/lociighostd"
else
    echo "==> WARNING: daemon dist not found at $DAEMON_DIST" >&2
    echo "    Run Scripts/build-daemon.sh first if you want a self-contained" >&2
    echo "    .app. Without this, end users will hit \"Daemon source not found\"" >&2
    echo "    because the app falls back to dev-mode staging from ~/Documents." >&2
fi

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
    <string>1.10.7</string>
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
    if [[ -d "$OUT/Contents/Resources/LociiGhost_LociiGhost.bundle" ]]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" \
            "$OUT/Contents/Resources/LociiGhost_LociiGhost.bundle"
    fi

    # Bundled PyInstaller daemon at Contents/Resources/lociighostd/.
    # PyInstaller's --onedir layout has the lociighostd executable
    # alongside _internal/ containing ~100 dylibs, Python C
    # extensions, and an embedded Python.framework whose main
    # binary file has no extension. Notary requires every Mach-O
    # file to be signed with hardened runtime + a secure timestamp;
    # --deep alone doesn't recurse into flat folders, and an
    # extension-based `find` misses extensionless framework binaries.
    # Use `file` to detect Mach-O regardless of name, sign each in
    # one pass, then sign the daemon's framework wrappers and the
    # main executable last so their seal covers everything below.
    if [[ -d "$OUT/Contents/Resources/lociighostd" ]]; then
        echo "==> signing every Mach-O inside Contents/Resources/lociighostd/"
        find "$OUT/Contents/Resources/lociighostd" -type f -print0 \
        | while IFS= read -r -d '' f; do
            if file -b "$f" | grep -q "Mach-O"; then
                codesign --force --options runtime --timestamp \
                    --sign "$SIGN_IDENTITY" "$f" 2>&1 | grep -v "replacing existing signature" || true
            fi
        done
        # Re-seal the embedded Python.framework wrapper (its
        # Versions/Current symlink + outer bundle ID) after the
        # inner binary has its signature.
        for fw in "$OUT/Contents/Resources/lociighostd/_internal"/*.framework; do
            if [[ -d "$fw" ]]; then
                codesign --force --options runtime --timestamp \
                    --sign "$SIGN_IDENTITY" "$fw"
            fi
        done
        echo "==> signing daemon main binary (top-level)"
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" \
            "$OUT/Contents/Resources/lociighostd/lociighostd"
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

        # The .zip was only needed as a transport for notarytool
        # submit (Apple won't notarise a bare .app). Now that the
        # ticket is stapled to the .app, the zip is dead weight —
        # delete it. Release artefact is the DMG produced below.
        rm -f "$ZIP"
        echo "==> notarised + stapled — ready for distribution"

        # Build the .dmg. This is the single distributable artefact
        # for end users: drag-to-Applications UX, signed + notarised
        # + stapled in its own right. make-dmg.sh runs the whole
        # build/sign/notarise/staple under /tmp and moves the
        # finished .dmg into dist/ at the end.
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
