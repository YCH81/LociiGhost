#!/usr/bin/env bash
# Launch the daemon with root privileges so iOS 17+ device.connect can
# create a utun interface for the RSD tunnel.
#
# Phase 1 dev convenience. Phase 4 replaces it with an SMAppService-managed
# LaunchDaemon that's approved once and runs without prompts thereafter.
#
# This script does the password prompt FIRST (via `sudo -v`), then kills
# any leftover daemon that might be holding the socket, and only then
# launches the privileged daemon. That order avoids the failure mode where
# the GUI app spawns its own unprivileged daemon while you're still
# typing your password.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
VENV_PY="$ROOT/Daemon/.venv/bin/python"
SOCKET="$HOME/Library/Application Support/LociiGhost/lociighost.sock"

if [[ ! -x "$VENV_PY" ]]; then
    echo "venv missing — run Scripts/build-daemon.sh first" >&2
    exit 1
fi

echo "==> requesting sudo (cached for the rest of this session)"
sudo -v

echo "==> stopping any lociighostd that's already holding the socket"
# Unprivileged ones we own.
pkill -TERM -u "$(id -u)" -f "python -m lociighostd" 2>/dev/null || true
# Stale sudo daemon from a previous run.
sudo pkill -TERM -f "python -m lociighostd" 2>/dev/null || true
# Also clean a dangling socket file so the new daemon binds cleanly.
rm -f "$SOCKET"

# Brief pause so the kernel finishes tearing down old listeners before
# we bind a new one on the same path.
sleep 0.3

LOG="$HOME/Library/Logs/LociiGhost/lociighostd-sudo.log"
mkdir -p "$(dirname "$LOG")"

# Past sudo-launched daemons can leave the log file (and sometimes
# the parent dir) owned by root. The redirect `>"$LOG"` on the next
# nohup line is set up by the user shell, NOT by sudo — so if the
# file is root-owned the shell can't truncate it and the launch
# fails with "Permission denied". Reclaim ownership while we still
# have a cached sudo from the `sudo -v` above. -R covers both the
# dir and the file in one shot; safe to run repeatedly.
sudo chown -R "$(whoami)" "$(dirname "$LOG")"

echo "==> launching daemon as root in the background"
echo "    socket: $SOCKET"
echo "    log:    $LOG"

# HOME ensures the daemon writes its log/socket under your user, not /var/root.
# nohup + setsid + & detach the process from this terminal: closing the
# terminal won't kill the daemon, and Cmd-Q'ing the Mac app won't either.
nohup sudo -E -H \
    PYTHONPATH="$ROOT/Daemon" \
    HOME="$HOME" \
    "$VENV_PY" -m lociighostd -v \
    >"$LOG" 2>&1 &

# Wait briefly for the socket to appear so we can confirm a clean start.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -S "$SOCKET" ]]; then
        break
    fi
    sleep 0.2
done

if [[ -S "$SOCKET" ]]; then
    echo
    echo "    daemon is running in the background. You can close this terminal."
    echo "    To stop the daemon manually: sudo pkill -f 'python -m lociighostd'"
    echo "    To follow the log:           tail -f \"$LOG\""
else
    echo
    echo "    socket did not appear in time. Check $LOG for errors." >&2
    exit 1
fi
