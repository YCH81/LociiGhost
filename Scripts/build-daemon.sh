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

# Detect a stale venv: shebangs inside .venv/bin are absolute paths
# baked at creation time, so renaming or moving the project root
# leaves the venv pointing at a non-existent interpreter. Recreate it
# if so, otherwise every console-script entry point (pip, pyinstaller,
# etc.) fails with "bad interpreter: No such file or directory".
VENV_DIR="$DAEMON_DIR/.venv"
VENV_BIN="$VENV_DIR/bin"
VENV_PY="$VENV_BIN/python3.13"

venv_is_stale() {
    [[ ! -x "$VENV_PY" ]] && return 0
    # The interpreter inside the venv is a symlink/shim back to the
    # real python3.13. If the real python3.13 isn't reachable from
    # within the venv, ANY install (pip, pyinstaller) will fail.
    "$VENV_PY" -c 'import sys' >/dev/null 2>&1 || return 0
    return 1
}

if [[ ! -d "$VENV_DIR" ]] || venv_is_stale; then
    echo "==> (re)creating venv (Python 3.13)"
    rm -rf "$VENV_DIR"
    python3.13 -m venv "$VENV_DIR"
fi

if ! "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    echo "==> bootstrapping pip inside venv"
    "$VENV_PY" -m ensurepip --upgrade
fi

echo "==> installing daemon + build deps"
"$VENV_PY" -m pip install --quiet --upgrade pip
"$VENV_PY" -m pip install --quiet -e ".[dev]"

# macOS Sequoia auto-flags some files in ~/Documents as UF_HIDDEN. Python 3.13's
# site.py refuses to load hidden .pth files, which silently breaks editable
# installs. Strip the flag so `python -m lociighostd` works from any cwd.
chflags nohidden .venv/lib/python*/site-packages/*.pth 2>/dev/null || true

echo "==> cleaning previous build"
rm -rf "$BUILD_DIR" "$DIST_DIR"

echo "==> running PyInstaller"
# Invoke via `python -m PyInstaller` instead of the pyinstaller
# console script — the script's shebang is an absolute path baked
# at install time, which breaks if the project ever gets renamed
# or moved. `python -m` uses whichever interpreter we explicitly
# call, so it's path-rename-safe.
"$VENV_PY" -m PyInstaller \
    --noconfirm \
    --clean \
    --name lociighostd \
    --onedir \
    --target-arch arm64 \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    --hidden-import lociighostd \
    --collect-submodules lociighostd \
    --add-data "lociighostd/static:lociighostd/static" \
    --exclude-module tkinter \
    --exclude-module test \
    --exclude-module unittest \
    --exclude-module xmlrpc \
    --exclude-module matplotlib \
    --exclude-module numpy.tests \
    lociighostd_entry.py
    # NOTE: IPython and pydoc are NOT excluded any more.
    # pymobiledevice3/utils.py does an unconditional top-level
    # `import IPython` (since pymobiledevice3 ~v4.x), and IPython
    # in turn imports pydoc at module load. Excluding either makes
    # the daemon crash on the first device call with
    # `ModuleNotFoundError`. Cost is ~4 MB on the bundle — unavoidable
    # until upstream makes those imports lazy.

echo
# macOS 26 Tahoe sporadically splits PyInstaller's output: a directory
# X gets paired with a sibling "X 2" containing files that should
# have been in X. The auto-rename can fire at the _internal level
# (most common) OR one level up at the lociighostd/ level — we've
# seen both. Sweep for any "<name> 2" sibling and rsync it back into
# the un-suffixed counterpart, repeating until no more splits remain
# (one pass might create new dup victims via the rsync overwrites,
# rare but cheap to defend).
merge_split_siblings() {
    local root="$1"
    local pass
    for pass in 1 2 3; do
        local found_any=0
        while IFS= read -r dup; do
            [[ -z "$dup" ]] && continue
            local base="${dup% 2}"
            if [[ -e "$base" ]]; then
                echo "==> merging Tahoe FS split: $dup → $base"
                rsync -a "$dup/" "$base/"
                rm -rf "$dup"
                found_any=1
            fi
        done < <(find "$root" -depth -name "* 2" 2>/dev/null)
        [[ $found_any -eq 0 ]] && break
    done
}
merge_split_siblings "$DIST_DIR"

echo "==> built: $DIST_DIR/lociighostd/lociighostd"
"$DIST_DIR/lociighostd/lociighostd" --version
