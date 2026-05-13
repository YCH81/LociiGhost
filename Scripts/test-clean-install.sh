#!/usr/bin/env bash
# test-clean-install.sh — simulate a fresh-Mac install of LociiGhost.
#
# Why this exists: v1.10.0 through v1.10.4 all shipped daemon / app
# bring-up bugs that only fired on machines without the developer's
# source tree, SwiftPM .build/ directory, staged daemon under
# ~/Library, etc. The dev environment was an invisible cradle of
# fallbacks (`Bundle.module`'s hardcoded buildPath, the staged daemon
# from previous runs, the source dir DaemonStaging defaulted to) that
# papered over the broken release paths.
#
# This script reproduces a "first install on a clean Mac" by
# temporarily moving everything the .app might reach for out of the
# way, then handing over to the DMG install ritual. The `trap` at
# the bottom guarantees the source tree is restored even if you
# Ctrl-C in the middle.
#
# Usage:
#     Scripts/test-clean-install.sh [<dmg-path>]
#
# If no DMG path is given, picks the most recently modified
# LociiGhost-v*.dmg under dist/.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SOURCE_DIR="$HOME/Documents/LociiGhost"
BAK_DIR="$HOME/Documents/LociiGhost.devbak.test"
APP_PATH="/Applications/LociiGhost.app"

# CFBundleIdentifier is `com.lociighost.app` (see Scripts/package-app.sh).
# The glob below picks that exact id and any future bundle-suffix
# variants the project might gain.
BUNDLE_PREFIX="com.lociighost"

# ── 0. Resolve which DMG we're testing ──────────────────────────
if [[ $# -ge 1 ]]; then
    DMG_SRC="$1"
else
    DMG_SRC="$(ls -t "$ROOT"/dist/LociiGhost-v*.dmg 2>/dev/null | head -1 || true)"
fi
if [[ -z "${DMG_SRC:-}" || ! -f "$DMG_SRC" ]]; then
    echo "❌ no DMG found. Pass the path as arg 1 or run Scripts/make-dmg.sh first." >&2
    exit 1
fi
echo "==> using DMG: $DMG_SRC"

# Refuse to blow over a previous interrupted run's backup. Manual
# inspection is the right escape hatch — we never want to lose
# uncommitted source by silently overwriting the bak dir.
if [[ -e "$BAK_DIR" ]]; then
    echo "❌ $BAK_DIR already exists — left over from a previous interrupted run." >&2
    echo "   Inspect it, then mv it back manually before re-running." >&2
    exit 1
fi

# ── trap: always restore the source tree, no matter how we exit ──
# Only restore if the bak exists AND the original is gone — protects
# against the (paranoid) case where the script crashes after the
# restore step but before exit.
cleanup() {
    if [[ -e "$BAK_DIR" && ! -e "$SOURCE_DIR" ]]; then
        echo
        echo "==> restoring $SOURCE_DIR from $BAK_DIR"
        mv "$BAK_DIR" "$SOURCE_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ── 1. Hide source tree ─────────────────────────────────────────
# Covers ~/Documents/LociiGhost/Daemon/ (the source DaemonStaging
# defaulted to in v1.10.0) and App/.build/.../release/...bundle
# (the hardcoded fallback path SwiftPM's `Bundle.module` accessor
# generates — saved the dev from v1.10.2 / v1.10.3 fatalErrors).
if [[ -d "$SOURCE_DIR" ]]; then
    echo "==> mv $SOURCE_DIR → $BAK_DIR"
    mv "$SOURCE_DIR" "$BAK_DIR"
fi

# ── 2. Remove previously-installed .app ─────────────────────────
if [[ -d "$APP_PATH" ]]; then
    echo "==> rm $APP_PATH"
    rm -rf "$APP_PATH"
fi

# ── 3. Clear ~/Library state ────────────────────────────────────
# Preferences, caches, network state, and any staged daemon — so
# the install under test is starting from zero.
echo "==> clearing ~/Library state for $BUNDLE_PREFIX.*"
rm -rf ~/Library/Preferences/"$BUNDLE_PREFIX".*.plist 2>/dev/null || true
rm -rf ~/Library/Caches/"$BUNDLE_PREFIX".* 2>/dev/null || true
rm -rf ~/Library/HTTPStorages/"$BUNDLE_PREFIX".* 2>/dev/null || true
rm -rf ~/Library/"Application Support"/LociiGhost 2>/dev/null || true
rm -rf ~/Library/"Application Support"/"$BUNDLE_PREFIX".* 2>/dev/null || true

# ── 4. ditto DMG to ~/Downloads with quarantine xattr ───────────
# Real users get LociiGhost via "download from website → double-click
# DMG", which arrives with `com.apple.quarantine` set. Setting it
# manually here gets us the same Gatekeeper check + first-launch
# "downloaded from internet" prompt, which is part of the user
# experience we want to verify.
DMG_NAME="$(basename "$DMG_SRC")"
DMG_DEST="$HOME/Downloads/$DMG_NAME"
echo "==> copying DMG to $DMG_DEST + quarantine attr"
ditto "$DMG_SRC" "$DMG_DEST"
QUARANTINE_UUID="$(uuidgen 2>/dev/null || echo '00000000-0000-0000-0000-000000000000')"
xattr -w com.apple.quarantine \
    "0083;$(printf '%08x' "$(date +%s)");TestCleanInstall;$QUARANTINE_UUID" \
    "$DMG_DEST" 2>/dev/null || \
    echo "   (xattr write failed — quarantine attr skipped; install will still proceed without Gatekeeper prompt)"

# ── 5. Hand over to manual install ──────────────────────────────
cat <<EOF

============================================================
Clean-room test environment ready.

Walk through the real-user install:
  1. Open $DMG_DEST (double-click in Finder)
  2. Drag LociiGhost.app into /Applications
  3. Launch LociiGhost from /Applications
  4. Wait ~30 seconds. Things to verify:
       • Main window appears (no immediate crash)
       • No "Daemon source not found" error toast
       • No "Bundle.module … could not load resource bundle"
         fatalError (would crash the .app)
       • Daemon process exists:
            pgrep -fl lociighostd
       • RPC channel is up: connect an iPhone or open Settings —
         neither should hang on a daemon-bringup timeout

When done — Quit LociiGhost first — press Enter here to put your
dev environment back.
============================================================
EOF
read -r -p "[press Enter to restore dev environment] "

# trap-driven cleanup will mv "$BAK_DIR" back into "$SOURCE_DIR" on
# exit. Nothing more to do here.
echo "==> done"
