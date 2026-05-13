# LociiGhost

<p align="right">
  <a href="README.md"><img alt="繁體中文" src="https://img.shields.io/badge/繁體中文-gray?style=flat-square"></a>
  <a href="README.en.md"><img alt="English" src="https://img.shields.io/badge/English-active-2d3748?style=flat-square"></a>
</p>

<p>
  <a href="https://ko-fi.com/jflociighost"><img alt="Support YCH81 (aka Jeff Hu) on Ko-fi" src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?style=flat-square&logo=kofi&logoColor=white"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-2d3748?style=flat-square"></a>
  <a href="https://drive.google.com/drive/folders/120WcPQLsSddBR_A4hDipw4USQGbMFHlf?usp=sharing"><img alt="Download (Google Drive)" src="https://img.shields.io/badge/download-DMG-7fa389?style=flat-square&logo=googledrive&logoColor=white"></a>
</p>

> **iPhone GPS spoofing tool** — Apple-Silicon-native macOS app, a complete Swift rewrite informed by LocWarp's concept and partial code reference (keezxc1223, MIT).
>
> Upstream: [keezxc1223/locwarp](https://github.com/keezxc1223/locwarp) (MIT)

A from-scratch, Apple-Silicon-only iOS location simulation tool inspired by
[LocWarp](https://github.com/keezxc1223/locwarp) (by keezxc1223, MIT-licensed),
but rebuilt as a native macOS application — not a port of the cross-platform
Electron version.

## Support

If LociiGhost is useful to you, buy me a coffee — or a bubble tea,
if you're in Taiwan.

[![Support YCH81 (aka Jeff Hu) on Ko-fi](https://img.shields.io/badge/Support%20YCH81%20%28aka%20Jeff%20Hu%29%20on%20Ko--fi-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white)](https://ko-fi.com/jflociighost)

## Download

- **Latest version**: v1.10.0
- **Release date**: 2026-05-13
- **Download**: [Google Drive folder](https://drive.google.com/drive/folders/120WcPQLsSddBR_A4hDipw4USQGbMFHlf?usp=sharing) — DMG is Apple-Developer-ID-signed and notarised, so it opens with a double-click without the Gatekeeper warning.

## New here?

👉 **Full user guide: [docs/user-guide.en.md](docs/user-guide.en.md)** — install, first launch, connecting your iPhone, running your first route, the six movement modes, and troubleshooting. Step by step.

## Features

- **Six movement modes** — Teleport, Navigate, Route Loop, Multi-Stop,
  Random Walk, Joystick.
- **Two phones, two iPhones at once** — Each phone can independently
  drive its own iPhone; sessions don't step on each other.
- **Per-device route memory** — Each iPhone keeps its own route,
  waypoints, and destination across sidebar switches.
- **Phone-as-remote-control web UI** — PIN-authenticated mobile page;
  drive the Mac side from an iPhone in your pocket.
- **GPX / bookmark import** — GPX tracks, LocWarp-format bookmark JSON,
  and bulk paste are all supported.
- **Hot speed swap** — Drag the SpeedPicker mid-playback; no re-routing.
- **Accurate ETA** — Recomputed from SpeedPicker so the time the UI
  shows matches the actual playback time.
- **Multiple routing engines** — OSRM public demo (default), Google
  Routes API (opt-in), or straight-line.
- **Live language switching** — UI flips between zh-Hant and English
  without restart.
- **Apple-Silicon-native** — 0% idle CPU, no Chromium overhead, bundle
  under 200 MB.

## What's new

**v1.10.0** (May 2026)

- **Apple MapKit added as a routing engine**, now the default. Four
  options total: MapKit / OSRM Public Demo / Google Directions /
  Straight line. MapKit needs no API key, integrates natively, and
  has excellent Taiwan-area data; cycling uses driving geometry while
  the SpeedPicker drives actual playback pace.
- **Chained leg stitching** kills the small "box detour" artefacts at
  multi-stop waypoints — each leg's origin is the previous leg's
  polyline END (an Apple-snapped road coordinate), so consecutive
  polylines share an endpoint by construction.
- **Pinned support footer at the bottom of the sidebar** (Ko-fi +
  LINE community buttons) that doesn't scroll with the rest of the
  sidebar content.
- **Red X is now standard Mac behaviour**: closing the last window
  hides it; the app stays in the Dock; Cmd-Q is what actually quits.
- TopStatusBar no longer char-wraps in narrow windows; window minimum
  raised to 1320×640 and sidebar locked at 280–310 pt.
- Simulated-iPhone pin always floats above the route polyline
  (z-priority fix).
- LICENSE gains a **Brand & Support Channels carve-out**: the name
  "LociiGhost", the icon, Ko-fi, and LINE channels are reserved to
  the author personally and not covered by MIT.
- Bilingual **GitHub Pages site**
  ([ych81.github.io/LociiGhost](https://ych81.github.io/LociiGhost/)),
  Ko-fi tip jar, LINE Official Account (`@382ydavk`) and community.
- Seven-section **Disclaimer**: lawful use, account-ban risk, system
  risk, map-data accuracy, support scope, user responsibility, no
  warranty.

**v1.9.4** (May 2026)

- Multi-phone control — the web control page on one iPhone can drive
  any other iPhone connected to the Mac (per-tab tokens and per-session
  `controlling_udid` keep concurrent sessions independent).
- Per-device route persistence — switching the active iPhone in the
  sidebar no longer wipes each device's route state.
- OSRM `NoRoute` auto-fallback — bike/foot retries as car when a
  waypoint pair has no path in the chosen profile.
- ETA recomputation — UI time tracks the SpeedPicker, so what you see
  matches what playback actually takes.
- Restore now shows a blue info toast explaining the 30 s–2 min
  iPhone GPS re-acquisition delay.

Full commit history: [git log](https://github.com/YCH81/LociiGhost/commits/main)

## Contact / Community

Join the LINE channels for release announcements and to chat with other
users:

[![LINE Official Account](https://img.shields.io/badge/LINE-Official%20Account-06C755?style=for-the-badge&logo=line&logoColor=white)](https://line.me/R/ti/p/%40382ydavk)
[![LINE Community](https://img.shields.io/badge/LINE-Community-06C755?style=for-the-badge&logo=line&logoColor=white)](https://line.me/ti/g2/-x9IldV0HMk-4Ydc-U93UnvOnUPbJ1En3z9XIg)

- LINE Official Account ID: `@382ydavk`
- LINE Community: "LociiGhost Mac/iOS 飛人" (primarily Traditional Chinese)
- Technical bug reports and feature requests: [GitHub Issues](https://github.com/YCH81/LociiGhost/issues)

## Why

The existing macOS port (`M-0.2.99.5`) is functional but architecturally a
direct lift from Windows: Electron renderer, web map, FastAPI HTTP server,
WebSocket bridge. On an M-series Mac this is **noticeably hot** — fan ramps
up, Activity Monitor shows hundreds of MB of Chromium overhead — the wrong
shape for a tool you leave open in the background.

This rebuild targets:

- **Idle = silent.** When no simulation is running the daemon is parked in
  `accept()` and the SwiftUI app does no background work.
- **Native rendering.** SwiftUI + MapKit, no Chromium, no Leaflet.
- **Single architecture.** arm64 only. Sub-200 MB bundle.
- **Same product concept.** Six movement modes, dual device sync, GPX import,
  bookmarks, ETA, hot speed swap.

## Repo layout

```
LociiGhost/
├── App/          Swift package (LociiGhostCore lib + lociighostctl CLI)
├── Daemon/       Python helper (lociighostd) using pymobiledevice3
├── Scripts/      build-daemon.sh, build-app.sh
└── docs/         rpc-protocol.md, etc.
```

## Phase 0 status (done)

> **Note**: This section documents the v0.1.0 early scaffolding. The project
> is now at v1.9.4 (Phase 0–5 + distribution phase all complete), with
> multi-phone independent control, per-device routes, Apple-Silicon-native
> daemon packaging, and Developer ID signing scaffolding. For the latest
> progress see [git log](https://github.com/YCH81/LociiGhost/commits/main).

Scaffolding and end-to-end RPC round-trip verified.

- Daemon project with `pyproject.toml`, JSON-RPC 2.0 server over Unix
  domain socket, 7 unit tests passing.
- `lociighostd` registers `ping`, `daemon.info`, `daemon.shutdown`.
- Swift package with `LociiGhostCore` (paths, JSON-RPC types, `DaemonClient`
  actor) and `lociighostctl` CLI; 2 Swift tests passing.
- Build scripts for both halves.

End-to-end measurements (May 2026, M-series, macOS 15.6.1):

- `lociighostctl ping` → `{"pong":true,"version":"0.1.0",...}` — round-trip
  < 5 ms
- Daemon idle CPU: **0.0%** after the connection settles
- Daemon idle RSS: ~22 MB
- Shutdown is graceful (signal handler + RPC method both work)

The `DaemonClient` deliberately puts the blocking `read(2)` on a background
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

- **macOS 14 (Sonoma) – macOS 26** — forward-compatible. Binary `minos`
  is 14.0; tested through macOS 15 / Sequoia day-to-day. Full compatibility
  matrix + verification commands in
  [`docs/compatibility.md`](docs/compatibility.md).
- **Apple Silicon (M1 / M2 / M3 / M4)** — Intel Macs are not supported
  by design (the rewrite drops Electron / Rosetta precisely to avoid that
  tax).
- **Python 3.13** via Homebrew: `brew install python@3.13`.
- **Swift 6** (Command-Line Tools enough for Phase 0; full Xcode needed
  from Phase 1 onward for SwiftUI).
- iPhone-side iOS **16 – 26**. USB works on every supported iOS; WiFi-only
  needs a one-time **Pair for WiFi** ritual (uses M-style RemotePairing —
  see Phase 4.5 in the changelog).
- Phase 4 WiFi tunnel: **no paid Developer Program membership needed** —
  admin elevation goes through `osascript "do shell script ... with
  administrator privileges"` instead of `SMAppService` (one Touch ID
  prompt per Mac restart).

## Attribution

LociiGhost is a complete native-Swift rewrite of
[LocWarp](https://github.com/keezxc1223/locwarp) by **keezxc1223**,
originally distributed under the MIT License. The product concept — six
movement modes, dual-device synchronisation, the phone-control web UI,
bookmark / GPX import flows, the OSRM-cached routing approach — was shaped
by LocWarp; several source files in this repository keep explicit "ported
from LocWarp" comments where the design parity is intentional.

LociiGhost itself (the new Swift app, Apple-Silicon-native daemon,
SwiftData schema, native MapKit integration, sage-palette paper-plane
icon set, and any feature work since v1.0) is the original work of
**YCH81 (Jeff Hu)**.

## License

LociiGhost's source code is distributed under the **MIT License** —
see [`LICENSE`](LICENSE) for the full text.

> ⚠️ **Brand is reserved, NOT covered by MIT.** See the **Brand &
> Support Channels** section in [`LICENSE`](LICENSE) for the full
> terms.

## Disclaimer

### 1. Lawful Use Only

This project was developed for use in GIS research, mobile app
development testing, location-service prototyping, personal map
exploration, and related technical exploration. Do not use this tool
for any unlawful purpose, or for any conduct that violates third-party
Terms of Service or platform policies.

### 2. Account Ban and Third-Party Service Risk

This tool modifies the iPhone's GPS simulation state, which may
violate the Terms of Service of certain apps, games, or
location-based games. Use at your own risk; account bans, progress
loss, and in-game-asset confiscation are possible, and the author
bears no responsibility for any such outcomes.

Use of this tool may violate the Terms of Service of third-party
platforms, resulting in account warnings, restrictions, bans, or
permanent termination, and the loss of accumulated in-game items,
progress, or stored credit. The author bears no responsibility for
any account loss, virtual-property damage, or downstream disputes
arising from the use of this tool.

### 3. System and Hardware Risk

This project requires administrator privileges to run. The code has
been internally tested, but the author cannot guarantee stable
operation across every macOS version, Apple Silicon model, or network
environment.

Users should assess these risks themselves and bear any resulting
consequences. This project only manipulates the temporary network
interface it creates and its own configuration files (located in
`~/Library/Application Support/LociiGhost/` and
`~/Library/Caches/LociiGhost/`); it does not modify any user data on
the iOS device, nor does it alter macOS kernel files or existing
device-pairing records.

### 4. Map Data Accuracy

Map rendering uses Apple MapKit (native basemap); route planning uses
the OSRM public demo (default) or Google Routes API (opt-in, requires
your own API key); geocoding optionally uses Google Geocoding API. The
coordinates, paths, and addresses shown on the map are **for reference
only**. The author does not guarantee their completeness, currency,
accuracy, or exact correspondence to real-world geography. Before
running a teleport, navigation, or random-walk based on address search
or route planning, users should verify that the displayed map matches
their expectations.

### 5. Test Environment and Support Scope

The software is **only validated on the developer's own test setup** —
macOS 15+ on Apple Silicon, iPhone 16 Pro Max / iOS 18.7–26.4. Other
device / iOS / macOS combinations are not guaranteed to work.

The project is maintained in the author's spare time; **no SLA, no
support desk**. Bug fixes, compatibility with new iOS releases, and
new features all depend on the author's available time and energy.

### 6. User Responsibility and Legal Compliance

Users are responsible for complying with the laws applicable where
they are, including but not limited to Taiwan's Personal Data
Protection Act, the Copyright Act, the Computer-Processed Personal
Data Protection Act, and equivalent international statutes. This tool
**must NOT** be used for fraud, harassment, unlawful circumvention of
geographical restrictions, or any purpose that causes harm to third
parties.

Any legal disputes, civil liability, or criminal liability arising
from misuse, mistaken use, or unlawful use of this tool are **borne
solely by the user**, and have no relation to the project's developer
or contributors.

### 7. No Warranty

This software is distributed under the MIT License and is provided
"AS IS", without warranty of any kind, express or implied, including
but not limited to warranties of merchantability, fitness for a
particular purpose, and non-infringement. Full legal terms are in
[`LICENSE`](LICENSE).
