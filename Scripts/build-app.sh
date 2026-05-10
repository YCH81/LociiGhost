#!/usr/bin/env bash
# Build the Swift package (LocWarpCore library + locwarpctl CLI).
#
# Phase 0: produces the locwarpctl CLI smoke client only.
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

CONFIG=${CONFIG:-release}
echo "==> swift build --configuration $CONFIG"
swift build --configuration "$CONFIG"

BIN="$APP_DIR/.build/$([ "$CONFIG" = "release" ] && echo arm64-apple-macosx/release || echo debug)/locwarpctl"
if [[ -f "$BIN" ]]; then
    echo "==> built: $BIN"
    "$BIN" --help || true
fi
