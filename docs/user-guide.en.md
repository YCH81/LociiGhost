# LociiGhost User Guide

<p align="right">
  <a href="user-guide.md"><img alt="繁體中文" src="https://img.shields.io/badge/繁體中文-gray?style=flat-square"></a>
  <a href="user-guide.en.md"><img alt="English" src="https://img.shields.io/badge/English-active-2d3748?style=flat-square"></a>
</p>

> For first-time LociiGhost users. From download to running your first route, step by step.

## Table of Contents

1. [What is LociiGhost](#1-what-is-lociighost)
2. [Before You Start](#2-before-you-start)
3. [First-Time Install](#3-first-time-install)
4. [First Launch: Interface Tour](#4-first-launch-interface-tour)
5. [Connecting Your iPhone (First Time)](#5-connecting-your-iphone-first-time)
6. [Run Your First Route](#6-run-your-first-route)
7. [The Six Movement Modes](#7-the-six-movement-modes)
8. [Routes and Bookmarks](#8-routes-and-bookmarks)
9. [Advanced: Control the Mac from Your Phone](#9-advanced-control-the-mac-from-your-phone)
10. [Speed and Routing Engines](#10-speed-and-routing-engines)
11. [Troubleshooting](#11-troubleshooting)
12. [Appendix](#12-appendix)

---

## 1. What is LociiGhost

LociiGhost is a macOS app that replaces your iPhone's GPS location with any place you pick on a map. Choose a location on your Mac, and your iPhone instantly believes it's there — every location-aware app on the iPhone (Maps, Fitness, social apps, games…) will see the new location.

**What it's for:**
- App developers testing location features without physically traveling
- Testing delivery / rideshare / map app behavior
- Personal map exploration, GIS research
- Previewing what a given place looks like on an iPhone

**What it's *not* for:**
- Anything that violates an app's Terms of Service (e.g. certain location-based games). This may **get your account permanently banned**. See [Section 2 warning](#2-before-you-start).

---

## 2. Before You Start

### Hardware
- **Mac**: Apple Silicon (M1 / M2 / M3 / M4). **Intel Macs are not supported** — by design, not a bug.
- **iPhone**: Any iPhone that can connect to your Mac via USB. iOS 17+ requires enabling Developer Mode (covered in Section 5.2).

### System
- **macOS**: 14 Sonoma or later. See [compatibility.md](compatibility.md) for the full compatibility matrix.

### Important Warning (please read in full)

> **Using LociiGhost may violate certain apps' Terms of Service.**
>
> Spoofing location on some apps — particularly location-based games, attendance systems, rideshare platforms — can trigger server-side detection and lead to:
>
> - **Permanent account bans**
> - **Permanent loss of game progress**
> - **Device ID blacklisting**
>
> LociiGhost itself is a neutral developer/testing tool, but how you use it is on you. **All consequences are your responsibility.** Full disclaimer in [Section 12 Appendix](#12-appendix).

---

## 3. First-Time Install

### Download
Go to the GitHub Releases page and grab the latest DMG:

👉 **https://github.com/YCH81/LociiGhost/releases**

Click the most recent version (e.g. `LociiGhost-v1.10.0.dmg`) to download.

### Install
1. Double-click the downloaded `.dmg` — a Finder window opens
2. Drag **LociiGhost.app** to the **Applications** folder
3. Open LociiGhost from Applications

### Possible First-Launch Warning

The first time you open it, macOS may show:

> **"LociiGhost can't be opened" — the developer can't be verified**

If you see this:

1. In Finder, navigate to Applications
2. **Control + Click** (or right-click) LociiGhost
3. Choose **Open**
4. The dialog now shows an **Open** button — click it
5. Won't bother you again

> v1.10.0+ is fully notarized by Apple, so this warning typically doesn't appear. If it does, follow the steps above once.

---

## 4. First Launch: Interface Tour

When LociiGhost opens, the window looks roughly like this:

```
┌─────────────────────────────────────────────────────────┐
│  ⬤ Auth status  [Search]    🌐 EN/中文   ⚙️ Settings    │ ← Top bar
├──────────────┬──────────────────────────────────────────┤
│              │                                          │
│  📱 Devices  │                                          │
│  ─────       │           🗺️  Map area                   │
│  📍 Routes   │      (Apple Maps, shows your location)   │
│  ⭐ Bookmarks│                                          │
│  🎮 Movement │                                          │
│              │                                          │
│  ─────       │                                          │
│  ☕ Support  │                                          │
│              │                                          │
├──────────────┴──────────────────────────────────────────┤
│  🚗 Car  🚲 Bike  🚶 Walk    Speed: [━━━━●━━━] 50 km/h  │ ← Bottom bar
└─────────────────────────────────────────────────────────┘
   ↑ Sidebar
```

### The Four Areas

| Area | What you do here |
|---|---|
| **Top bar** | See auth status (green = OK, red = needs auth), search places, switch language, open Settings |
| **Sidebar** | See connected iPhones, saved routes/bookmarks, pick movement modes |
| **Map area** | Click to pick a destination, preview routes, see the iPhone's current location |
| **Bottom bar** | Pick a travel mode, drag the speed slider (also works during playback) |

### Two Things to Do First

**1. Confirm the language**

Click ⚙️ Settings (top-right) or press `⌘ + ,`, find **Language**, and switch between **English / 繁體中文** on the fly — no restart needed.

**2. Allow Mac location access (auto-prompted)**

On first launch, macOS asks "LociiGhost would like to use your location" — click **Allow**.
This is just so the map can center on where you are. No location data ever leaves your Mac.

---

## 5. Connecting Your iPhone (First Time)

For your first connection, **strongly recommend USB**. WiFi connection requires pairing once via USB first.

### 5.1 USB Connection (do this first)

1. Plug your iPhone into the Mac with a USB cable
2. The iPhone shows a dialog: **"Trust This Computer?"**
3. Tap **Trust** on the iPhone and enter your iPhone passcode
4. After a few seconds, your iPhone appears in LociiGhost's sidebar (with a USB badge)

If the iPhone doesn't appear, see [Section 11 Troubleshooting](#11-troubleshooting).

### 5.2 Enable Developer Mode (required for iOS 17+)

iOS 17 and later require Developer Mode to be turned on for location simulation to work.

**On the iPhone:**

1. Settings → Privacy & Security
2. Scroll to the bottom and find **Developer Mode**
3. Toggle it on
4. The iPhone asks to restart — do it
5. After reboot, confirm the prompt and enter your passcode

> Don't see Developer Mode? It only appears after the iPhone has been recognized by a Mac running developer tools. Complete Section 5.1 USB connection first with LociiGhost open, then go back to iPhone Settings.

LociiGhost has a shortcut button to take you there: click **Enable Developer Mode…** next to your device in the sidebar.

### 5.3 Authenticate LociiGhost (one Touch ID)

The first time you connect an iOS 17+ device, the top of LociiGhost shows a red banner:

> **"Authentication required"** — click the **Authenticate** button on the right

After clicking:

1. macOS shows a Touch ID prompt
2. Press your fingerprint (or enter your Mac password)
3. The banner disappears, auth status turns green

**This is needed once per Mac restart**, not per app launch. Reopening the app doesn't require re-authentication.

> Why authenticate? Short answer: LociiGhost needs Mac-level permission to talk to your iPhone — a requirement Apple added in iOS 17.

### 5.4 Switching to WiFi Later (no cable)

Once USB works, you can pair for WiFi so future connections don't need a cable.

How: in the sidebar, next to your device, open the menu and pick **Pair for WiFi**. Follow the prompts (you'll see the "Trust This Computer" dialog twice). After that, you can connect over WiFi with no cable.

Full WiFi setup guide → **[wifi-setup.md](wifi-setup.md)**

---

## 6. Run Your First Route

iPhone connected. Five minutes to see your iPhone's location actually change.

### Fastest Check: Teleport to a Place

1. **Find a place on the map** (e.g. Tokyo Station, Times Square)
   - Drag/zoom the map to find it
   - Or use the search bar at the top
2. **Click that spot on the map**
   - A blue pin drops
   - A floating panel offers **Teleport / Navigate**
3. **Click Teleport**
4. **Pick up your iPhone**, open the Maps app
5. The iPhone's location **jumps to where you picked**

> ⏱️ iPhone GPS recalibration takes **30 seconds to 2 minutes**. If you still see the old location at first, wait a bit.

### Next: Simulate Moving There

Teleport jumps instantly — it doesn't simulate travel. To simulate actually moving from your current location to a destination (super useful for testing navigation apps):

1. Repeat steps 1–2 above to pick a destination
2. In the floating panel, click **Navigate**
3. In the bottom bar, pick a travel mode: **🚗 Car / 🚲 Bike / 🚶 Walk**
4. Drag the **Speed** slider to set your desired km/h
5. Click **Start**
6. Watch the iPhone marker move along the route on the map

During playback you can drag the speed slider — speed changes instantly and the ETA recalculates.

---

## 7. The Six Movement Modes

Open the **Movement Modes** section in the sidebar and you'll see:

| Mode | Purpose | Best for |
|---|---|---|
| **Teleport** | Jump iPhone to a single point | Most common, fastest validation |
| **Navigate** | Plan a route and simulate travel at speed | Testing navigation / delivery / rideshare apps |
| **Route Loop** | Repeat the same route N times | Long-running tests, patrol simulation |
| **Multi-stop** | Visit multiple waypoints, pause at each | Commute simulation, multi-drop delivery |
| **Random** | Wander randomly within a radius | Simulating "active in this area" |
| **Joystick** | Manual control with arrow keys or on-screen joystick | Interactive testing |

Plus one game-specific mode:

- **Gold Ditto** — for Pikmin Bloom players, mimics a specific spawn pattern. Most users won't need this.

### How Each Mode Works

**Teleport** — already shown in Section 6. Click map, click Teleport. Done.

**Navigate** — also shown in Section 6. You can also add intermediate stops: click point 1 on the map, then click point 2, and LociiGhost will chain them into a route.

**Route Loop** — in multi-stop mode or with an imported route, set the **Laps** count (1–99) to repeat.

**Multi-stop** — click **Multi-stop** in the sidebar to enter the mode. Click waypoints on the map in order. Each waypoint can have a configurable dwell time. Click Start and the iPhone visits each in sequence, pausing at each.

**Random** — click **Random** in the sidebar. Configure radius and number of steps. Click Start and the iPhone wanders within the radius.

**Joystick** — click **Joystick** in the sidebar to activate. Then use arrow keys, or the on-screen joystick, to push the iPhone around in real time. Great for testing apps that react to motion.

---

## 8. Routes and Bookmarks

LociiGhost organizes saved places into two categories: **Bookmarks** (single points) and **Routes** (paths).

### Bookmarks: One-Click Jumps

**Add a bookmark:**
1. **Control + Click** (or right-click) anywhere on the map
2. Choose **Save as bookmark…**
3. Name it, click Save

**Use a bookmark:**
- The **Bookmarks** section in the sidebar lists all of them
- Click the **Teleport here** button next to any bookmark to jump there

**Bulk import:**
If you've exported bookmarks as JSON from LocWarp or another tool, paste them all at once: Bookmarks section menu → **Import bookmarks from JSON** → paste your JSON.

### Routes: Save Full Paths for Replay

**Import a GPX route:**
1. Menu bar: **File ▸ Import GPX…** (or `⌘O`)
2. Pick a `.gpx` file
3. The route appears in the sidebar's **Routes** section

**Export the current route:**
1. With a route planned, menu bar: **File ▸ Export current route as GPX…** (or `⌘E`)
2. Save the `.gpx` — share it or replay later

**Replay a route:**
In the sidebar's **Routes** section, click any route. A confirmation appears: "Teleport to the start and navigate through N points?" — confirm to play.

**Save multi-stops as a route:**
After arranging stops in multi-stop mode, click **Save as new route** to persist the trip for later replay.

---

## 9. Advanced: Control the Mac from Your Phone

Want to change locations without being at your Mac? LociiGhost has a phone-side web UI — open it in Safari on your iPhone and drive the Mac from there.

### Setup

**On the Mac:**

1. In the sidebar, click **Phone Control**
2. The window shows:
   - A URL like `http://192.168.1.5:8779/phone`
   - A 6-digit PIN

**On the iPhone:**

3. Make sure the iPhone is on the **same Wi-Fi** as the Mac
4. Open Safari, type the URL
5. Enter the PIN
6. You're in the phone control UI

### What the Phone Can Do

- Search for a place → Teleport or Navigate
- One-tap teleport from bookmarks
- Adjust speed in real time
- Start / pause / stop active routes

### Security Notes

- **The PIN regenerates every time the daemon restarts**, including after a Mac restart. Come back to LociiGhost to see the new PIN.
- Want to kick all paired phones immediately? Click **Regenerate PIN**.
- Multiple phones can connect, but only one can drive the currently-selected iPhone at a time.

---

## 10. Speed and Routing Engines

### Speed Slider

The **Speed** slider in the bottom bar goes from 0 to 200+ km/h. **You can drag it during playback** — speed updates instantly and the ETA recalculates.

### Laps

To loop a route, set **Laps** in the route playback panel (up to 99).

### Routing Engines (Which Map Service Plans Your Route)

In Navigate mode, LociiGhost plans a route automatically. Pick the engine in ⚙️ Settings → **Routing engine**:

| Engine | Pros | Best for |
|---|---|---|
| **Apple Maps** (default) | No setup, great Taiwan data, native integration | Most situations |
| **OSRM public demo** | Free, true bike-network paths | Realistic bike routes when speed isn't critical |
| **Google Directions** | High-quality globally | If you have your own Google API key |
| **Straight line** | No road snapping, direct point-to-point | Indoor / off-road / quick testing |

Stick with the default (Apple Maps) unless you have a reason to change it.

---

## 11. Troubleshooting

### Install

**Q: Got "developer cannot be verified" on first launch?**
A: Control + Click (right-click) → **Open**. One-time fix, see [Section 3](#3-first-time-install).

**Q: I have an Intel Mac, can I use this?**
A: No. LociiGhost only supports Apple Silicon (M1/M2/M3/M4).

### Connection

**Q: My iPhone never shows up in the sidebar.**
A: Check in order:
1. Is the USB cable working? Try a different one.
2. Did you tap **Trust This Computer** on the iPhone? If not, unplug and replug.
3. iOS 17+ — is Developer Mode on? (Section 5.2)
4. Try restarting LociiGhost.

**Q: The top bar is stuck on red "Authentication required".**
A: Click **Authenticate**, complete Touch ID. Required once per Mac restart for iOS 17+ devices.

**Q: WiFi connection won't work.**
A: Make sure the iPhone and Mac are on the **same Wi-Fi**. Public Wi-Fi (cafés, hotels) often blocks peer-to-peer traffic — fall back to USB, or use iPhone Personal Hotspot to the Mac (always works). Full WiFi guide: [wifi-setup.md](wifi-setup.md).

### Usage

**Q: I clicked Teleport but the iPhone's location hasn't changed.**
A: Wait 30 seconds to 2 minutes. iPhone GPS recalibration takes time. Not a bug.

**Q: My route stopped halfway through.**
A: Usually the iPhone's screen has been locked too long. Wake the iPhone — the connection auto-restores. If not, go to LociiGhost and check auth status; re-authenticate if needed.

**Q: How do I fully stop simulation and have the iPhone return to its real location?**
A: Press Stop in LociiGhost to end simulation. For a hard reset: restart the iPhone — that clears all simulation state.

**Q: Can I control two iPhones at once?**
A: Yes. Connect both — they appear separately in the sidebar. Click to switch between them. Each iPhone has its own route, bookmarks, and state; switching never loses anything.

**Q: Does my location get sent to Apple, Google, or anyone?**
A: No. LociiGhost runs entirely on your Mac and never uploads location data.

### Advanced

**Q: Will I get banned in Pokémon GO / Pikmin / other games?**
A: Possibly. See [Section 2 warning](#2-before-you-start). **You assume the risk.**

**Q: Does LociiGhost work with Android phones?**
A: No, iPhone only.

---

## 12. Appendix

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘ ,` | Open Settings |
| `⌘ O` | Import GPX |
| `⌘ E` | Export current route as GPX |
| `⌘ Q` | Quit LociiGhost |
| Arrow keys ↑↓←→ | Move iPhone in Joystick mode |

> The red X in the window title is **close window**, not quit — standard Mac behavior. To fully quit, press `⌘ Q`.

### Full Disclaimer

1. **Lawful use only.** LociiGhost provides location simulation. Use it within the laws of your jurisdiction and the terms of service of any target app.
2. **Account ban risk.** Location spoofing may violate the ToS of certain apps (location-based games, attendance, rideshare, etc.) and may result in permanent account bans and loss of progress.
3. **System risk.** Despite best-effort compatibility work, location simulation depends on iOS developer interfaces, which may misbehave on some iOS versions. Restarting the iPhone typically clears any issue.
4. **Map accuracy.** Route planning relies on third-party map services (Apple, OSRM, Google) and may be inaccurate.
5. **Support scope.** This is a personal project. No guarantee of uninterrupted service or future compatibility.
6. **User responsibility.** Any consequences of using this tool — including account loss, data loss, and third-party legal issues — are entirely your responsibility.
7. **No warranty.** The software is provided "as is," with no warranties of any kind, express or implied.

### Support the Author

If LociiGhost is useful to you, consider buying the developer a coffee:

- ☕ **Ko-fi**: [ko-fi.com/jflociighost](https://ko-fi.com/jflociighost)

### Join the Community

- 📢 **LINE Official Account**: [@382ydavk](https://line.me/R/ti/p/%40382ydavk)
- 👥 **LINE Community**: "LociiGhost Mac/iOS 飛人" → [join link](https://line.me/ti/g2/-x9IldV0HMk-4Ydc-U93UnvOnUPbJ1En3z9XIg)

Bug reports and feature requests are welcome in either channel.

### Credits

LociiGhost is a complete Swift rewrite, but its concept and parts of the approach are inspired by [keezxc1223/locwarp](https://github.com/keezxc1223/locwarp) (MIT). Big thanks to the upstream project.
