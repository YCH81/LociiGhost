# Compatibility matrix

Verified for **macOS 14 (Sonoma) → macOS 26** on Apple Silicon. The
LociiGhost binary is compiled with `minos 14.0` against the macOS
26.2 SDK; Apple maintains forward ABI compatibility, so any 14.x or
later release reads the binary metadata correctly.

## Mac side

| Requirement       | Notes |
|-------------------|-------|
| **macOS 14 – 26** | App's `Info.plist LSMinimumSystemVersion` is `14.0`. Tested on Sequoia (15) day-to-day; Sonoma (14) is the floor. macOS 14.4+ recommended for the live-switch language picker (`.environment(\.locale, ...)` + `LocalizedStringKey` had bugs in 14.0 / 14.1). |
| **Apple Silicon (M1 / M2 / M3 / M4)** | `package-app.sh` builds `arm64-apple-macosx`. **Intel Macs are not supported by design** — the project's whole motivation is to drop the Electron / Rosetta tax of the LocWarp fork. |
| **Homebrew Python 3.13** | `brew install python@3.13`. The daemon's venv lives under `Daemon/.venv` and links against `/opt/homebrew/.../python3.13`; future stand-alone packaging (Phase 5.5) will bundle Python via PyInstaller. |
| **`pymobiledevice3 >= 9.12`** | Pinned in `Daemon/pyproject.toml`. Each iOS release tends to need a fresh `pymobiledevice3`; if Apple ships iOS 27 with new tunnel quirks, expect an upstream bump. |

The runtime daemon process needs root for `utun` creation (iOS 17+
tunnels). The desktop GUI elevates it via `osascript "do shell script
... with administrator privileges"` — one Touch ID prompt per Mac
restart, no manual `sudo`.

## iPhone side

| iOS version | Status |
|-------------|--------|
| 16.x        | Works via legacy `DtSimulateLocation` over usbmux lockdown. |
| 17.0 – 17.x | Works via `DvtLocationService` over a `CoreDeviceTunnelProxy` RSD tunnel (USB) or RemotePairing (WiFi). |
| 18.0 – 18.x | Same as 17 — Apple swapped QUIC for TCP in the tunnel transport but pymobiledevice3's `get_rsds()` handles both. |
| **26.x**    | Works via the M-style RemotePairing repair flow (Pair for WiFi button) for true cable-free operation. RemotePairing's RSD service map is stripped of `dtservicehub` on iOS 26, so the daemon falls back to opening a USB-tunnel-RSD when needed (also handled automatically). |

## Phone-control web UI

The mobile control page (`/phone` served by the daemon's HTTP
server) uses Leaflet 1.9.4 from unpkg. Tested on:

| Browser            | Status |
|--------------------|--------|
| Mobile Safari (iOS 17 – 26) | ✅ |
| Chrome on iOS / Android     | ✅ (touch joystick verified) |
| Desktop Safari / Chrome     | ✅ but the layout is mobile-optimised (small map, FAB) |

The HTTP server picks the first free port from `[8779, 8780, 8781,
8788, 8789, 8800]` so it doesn't fight the older LocWarp Electron
build's port 8777 if it happens to be running on the same Mac.

## Verifying yourself

```bash
otool -l dist/LociiGhost.app/Contents/MacOS/LociiGhost \
    | grep -A4 LC_BUILD_VERSION
# expected:
#       cmd LC_BUILD_VERSION
#   cmdsize 32
#  platform 1
#     minos 14.0
#       sdk 26.2
```

`platform 1 = macOS`. `minos 14.0` is the floor any future macOS
needs to honour for this binary to launch.

## Known forward-compat risks

1. **pymobiledevice3 + iOS futures** — every iOS version tends to
   tweak the developer-tunnel handshake. Track the upstream
   project's release notes; a daemon dep bump is usually all
   that's needed.
2. **`osascript "with administrator privileges"`** — Apple has
   periodically tightened this path. If a future macOS removes it
   we'd switch to `SMAppService` (which we already considered for
   Phase 4 but skipped because it needs Developer-ID signing).
3. **SwiftData schema migration** — the `AppPreferences` model
   today is one row, four scalar fields. Future schema additions
   (Phase 5.3 bookmarks, etc.) will need explicit
   `MigrationPlan` definitions. The current code falls back to an
   in-memory store on schema mismatch so the app still launches.
4. **Bundle.module localisation lookup** — SwiftPM lowercases
   `.lproj` directory names during resource processing, so
   `package-app.sh` copies `Sources/LociiGhost/Resources/*.lproj`
   straight from source into `Contents/Resources/` to preserve
   `zh-Hant.lproj`'s casing. If SwiftPM's behaviour changes in a
   future toolchain, the duplicate copy keeps things working.

## Architecture decisions logged

- **arm64-only**: rejected universal-binary for ~50% smaller `.app`
  size and zero Rosetta launch cost.
- **No SMAppService LaunchDaemon**: `osascript` admin elevation is
  enough for personal/research use and avoids the Developer-ID
  paid-membership gate.
- **JSON-RPC over Unix socket** (not gRPC, not HTTP for the desktop
  channel): minimal deps on both sides; the phone-control HTTP
  server is a separate FastAPI process spawned in the same asyncio
  loop, which lets us reuse the daemon's existing
  `DeviceManager` instance directly without an IPC hop.
