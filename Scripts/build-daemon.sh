#!/usr/bin/env bash
# Build a self-contained arm64 lociighostd binary using PyInstaller.
# Output: Daemon/dist/lociighostd/lociighostd  (and a sibling _internal/ dir)
#
# Design notes (see plan, "性能與散熱"):
# - --onedir, NOT --onefile: avoid the "extract to /tmp on every launch"
#   CPU/IO spike that --onefile causes.
# - --target-arch arm64: hard-fail if running on Intel; we don't ship universal.
# - --exclude-module: drop modules pymobiledevice3 doesn't actually need at
#   runtime so the bundle stays small and starts faster.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DAEMON_DIR="$ROOT/Daemon"
DIST_DIR="$DAEMON_DIR/dist"
BUILD_DIR="$DAEMON_DIR/build"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "build-daemon.sh requires Apple Silicon (arm64). Got $(uname -m)." >&2
    exit 1
fi

cd "$DAEMON_DIR"

if [[ ! -d ".venv" ]]; then
    echo "==> creating venv (Python 3.13)"
    python3.13 -m venv .venv
fi

# shellcheck source=/dev/null
source .venv/bin/activate

echo "==> installing daemon + build deps"
pip install --quiet --upgrade pip
pip install --quiet -e ".[dev]"

# macOS Sequoia auto-flags some files in ~/Documents as UF_HIDDEN. Python 3.13's
# site.py refuses to load hidden .pth files, which silently breaks editable
# installs. Strip the flag so `python -m lociighostd` works from any cwd.
chflags nohidden .venv/lib/python*/site-packages/*.pth 2>/dev/null || true

echo "==> cleaning previous build"
rm -rf "$BUILD_DIR" "$DIST_DIR"

echo "==> running PyInstaller"
pyinstaller \
    --noconfirm \
    --clean \
    --name lociighostd \
    --onedir \
    --target-arch arm64 \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    --hidden-import lociighostd \
    --exclude-module tkinter \
    --exclude-module test \
    --exclude-module unittest \
    --exclude-module pydoc \
    --exclude-module xmlrpc \
    --exclude-module pdb \
    --exclude-module IPython \
    --exclude-module matplotlib \
    --exclude-module numpy.tests \
    lociighostd/__main__.py

echo
echo "==> built: $DIST_DIR/lociighostd/lociighostd"
"$DIST_DIR/lociighostd/lociighostd" --version
