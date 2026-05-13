#!/usr/bin/env bash
# Build the Swift package (LociiGhostCore library + lociighostctl CLI).
#
# Phase 0: produces the lociighostctl CLI smoke client only.
# Phase 1+: will additionally drive xcodebuild for the full SwiftUI .app bundle
#           (requires full Xcode -- not just Command Line Tools).

set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="$(pwd)/App"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "build-app.sh requires Apple Silicon (arm64). Got $(uname -m)." >&2
    exit 1
fi

cd "$APP_DIR"

# Guard: never let `bundle: .module` reach a packaged build.
# SwiftPM's executable-target accessor hardcodes the developer's
# absolute `.build/` path as its only fallback, so any
# `String(localized: …, bundle: .module, …)` crashes the .app on
# launch on every machine except this one (and even on this one if
# the source tree moves). The fix is to drop `bundle: .module`
# everywhere — `Bundle.main` finds the .lproj files that
# package-app.sh copies into Contents/Resources/. See the long
# comment block at the top of Scripts/package-app.sh for the full
# story.
if grep -rn "bundle: \.module" Sources/LociiGhost --include="*.swift" 2>/dev/null; then
    echo "❌ bundle: .module is not allowed in this project — it crashes the packaged .app on launch." >&2
    echo "   Use String(localized: \"…\") without a bundle argument." >&2
    echo "   See Scripts/package-app.sh comment block for why." >&2
    exit 1
fi

CONFIG=${CONFIG:-release}
echo "==> swift build --configuration $CONFIG"
swift build --configuration "$CONFIG"

BIN="$APP_DIR/.build/$([ "$CONFIG" = "release" ] && echo arm64-apple-macosx/release || echo debug)/lociighostctl"
if [[ -f "$BIN" ]]; then
    echo "==> built: $BIN"
    "$BIN" --help || true
fi
