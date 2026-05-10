# LociiGhost

A from-scratch, Apple-Silicon-only iOS location simulation tool inspired by
[LociiGhost](https://github.com/keezxc1223/lociighost), but rebuilt as a native
macOS application — not a port of the cross-platform Electron version.

## Why

The existing macOS port (`M-0.2.99.5`) is functional but architecturally a
direct lift from Windows: Electron renderer, web map, FastAPI HTTP server,
WebSocket bridge. On an M-series Mac this is **noticeably hot** — fan ramps
up, Activity Monitor shows hundreds of MB of Chromium overhead — which is
the wrong shape for a tool you leave open in the background.

This rebuild targets:

- **Idle = silent.** When no simulation is running the daemon is parked in
  `accept()` and the SwiftUI app does no background work.
- **Native rendering.** SwiftUI + MapKit, no Chromium, no Leaflet.
- **Single architecture.** arm64 only. Sub-200 MB bundle.
- **Same product concept.** Six movement modes, dual device sync, GPX import,
  bookmarks, ETA, hot speed swap.

See [`/Users/ych/.claude/plans/lociighost-copy-0-mac-m-keen-harbor.md`](../../.claude/plans/lociighost-copy-0-mac-m-keen-harbor.md)
for the full plan, including the thermal/power section that drives most
implementation decisions.

## Repo layout

```
LociiGhost/
├── App/          Swift package (LociiGhostCore lib + lociighostctl CLI)
├── Daemon/       Python helper (lociighostd) using pymobiledevice3
├── Scripts/      build-daemon.sh, build-app.sh
└── docs/         rpc-protocol.md, etc.
```

## Phase 0 status (done)

Scaffolding and end-to-end RPC round-trip verified.

- Daemon project with `pyproject.toml`, JSON-RPC 2.0 server over Unix
  domain socket, 7 unit tests passing.
- `lociighostd` registers `ping`, `daemon.info`, `daemon.shutdown`.
- Swift package with `LociiGhostCore` (paths, JSON-RPC types, `DaemonClient`
  actor) and `lociighostctl` CLI; 2 Swift tests passing.
- Build scripts for both halves.

End-to-end measurements (May 2026, on M-series, macOS 15.6.1):

- `lociighostctl ping` → `{"pong":true,"version":"0.1.0",...}` — round-trip < 5 ms
- Daemon idle CPU: **0.0%** after the connection settles
- Daemon idle RSS: ~22 MB
- Shutdown is graceful (signal handler + RPC method both work)

The DaemonClient deliberately puts the blocking `read(2)` on a background
thread, **off the actor's executor**, to avoid deadlocking the actor when
a syscall blocks. See `App/Sources/LociiGhostCore/DaemonClient.swift`.

Not yet done (next phases):

- **Full Xcode required** for the SwiftUI `.app` bundle. Command-Line Tools
  alone build the Swift CLI and the core library, but cannot link a SwiftUI
  app or produce a notarisable `.app`.
- Phase 1: USB device discovery + teleport (`device.list`, `device.connect`,
  `location.teleport`).
- Phases 2–5: see plan.

## Quick test (Phase 0 smoke)

```bash
# 1. Build the daemon
./Scripts/build-daemon.sh

# 2. Run it (foreground)
cd Daemon && source .venv/bin/activate
lociighostd --socket /tmp/lw.sock -v &

# 3. Talk to it from Swift
cd ../App && swift run lociighostctl --socket /tmp/lw.sock ping
# => {"pong":true,"version":"0.1.0", ...}

# 4. Shut it down
swift run lociighostctl --socket /tmp/lw.sock shutdown
```

## Requirements

- **macOS 14 (Sonoma) – macOS 26** — forward-compatible. Binary
  `minos` is 14.0; tested through macOS 15 / Sequoia day-to-day.
  Full compatibility matrix + verification commands in
  [`docs/compatibility.md`](docs/compatibility.md).
- **Apple Silicon (M1 / M2 / M3 / M4)** — Intel Macs are not
  supported by design (the rewrite drops Electron / Rosetta exactly
  to avoid that tax).
- **Python 3.13** via Homebrew: `brew install python@3.13`.
- **Swift 6** (Command-Line Tools enough for Phase 0; full Xcode
  needed from Phase 1 onward for SwiftUI).
- iOS **16 – 26** on the iPhone side. USB works on every
  supported iOS; WiFi-only via the one-time **Pair for WiFi**
  ritual (uses M-style RemotePairing, see Phase 4.5 in the
  changelog).
- Phase 4 WiFi tunnel: **no paid Developer Program membership
  needed** — admin elevation goes through `osascript "do shell
  script ... with administrator privileges"` instead of
  `SMAppService` (one Touch ID prompt per Mac restart).

## License

MIT (matches upstream LociiGhost).
