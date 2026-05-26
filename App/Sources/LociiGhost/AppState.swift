import AppKit
import CoreLocation
import Foundation
import SwiftData
import Observation
import SwiftUI
import UniformTypeIdentifiers
import LociiGhostCore

// MARK: - Debug file logger (DwellMonitor diagnostic only)
private let _dwellLogURL = URL(fileURLWithPath: "/tmp/dwell_debug.txt")
private func dwellLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: _dwellLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: _dwellLogURL) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            }
        } else {
            try? data.write(to: _dwellLogURL)
        }
    }
}

/// Top-level @Observable state for the SwiftUI app.
///
/// Holds the long-lived `DaemonClient` actor and surfaces device/connection
/// state for views. Views observe individual fields — SwiftUI will only
/// re-render the parts that change.
@MainActor
@Observable
final class AppState {
    // MARK: - Connection
    enum DaemonStatus: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .failed(let s): return "Failed: \(s)"
            }
        }
    }

    var daemonStatus: DaemonStatus = .stopped
    var daemonVersion: String = ""
    var lastError: String?

    /// Non-error informational toast (blue, auto-dismissing). Used for
    /// nudges that aren't failures — e.g. "real GPS may take a minute
    /// to re-acquire after Restore". `lastError` stays reserved for
    /// actual failures so the colour coding in the overlay stays
    /// meaningful.
    var lastInfo: String?
    private var infoDismissTask: Task<Void, Never>?

    /// Show an info toast for ~10 seconds, then auto-dismiss. Cancels
    /// any previous pending dismiss so a second call doesn't blink the
    /// previous toast away early.
    func showInfo(_ text: String) {
        lastInfo = text
        infoDismissTask?.cancel()
        infoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastInfo = nil
        }
    }

    // MARK: - Devices
    var devices: [DeviceVM] = []
    var selectedUDID: String?

    // MARK: - Pending teleport / stops
    /// Ordered list of points the user has staged on the map but not yet
    /// committed. Each click on the map (or each successful search) appends
    /// a new stop. Navigate consumes the entire list as an in-order
    /// multi-waypoint route. Teleport uses the *last* stop only.
    // didSet on @Observable array properties does not fire reliably for
    // in-place mutations (`.append`, `.remove(at:)`); the @Observable
    // macro routes those through `_modify` which skips willSet/didSet.
    // The view layer drives `schedulePreviewRefresh()` via `.onChange`
    // instead — see MainView's bootstrap modifiers.
    var pendingStops: [Coordinate] = []

    /// Which movement-modes panel the user has open in the sidebar.
    /// Lifted out of `MovementModesSection`'s local `@State` so the
    /// rest of the app (map click handler, control panel, etc.) can
    /// react. nil → no panel open, map click is inert.
    ///
    /// v1.11.0: when the user switches AWAY from Multi-Stop, the
    /// staged `pendingStops` list is cleared. Without this, stops
    /// staged for one feature would linger in state after the user
    /// moved on to Random Walk / Joystick / etc., visible in any
    /// future Multi-Stop session. Spec ("跳到別的功能" should clear)
    /// is exactly this transition.
    var activeMovementMode: MovementMode? = nil {
        didSet {
            if oldValue == .multiStop && activeMovementMode != .multiStop {
                pendingStops = []
            }
        }
    }

    /// v1.11.2 round 17: per-device snapshots of the active movement
    /// mode + pending stops. AppState's `activeMovementMode` and
    /// `pendingStops` are visible to the UI as single global values,
    /// but each device gets its own slot saved here on
    /// device-switch and restored on switch-back. Without this, a
    /// user with iPhone A staged for multi-stop who briefly clicks
    /// Map or iPhone B comes back to a blank multi-stop panel and
    /// thinks their staging vanished.
    private var savedModesByDevice: [String: MovementMode] = [:]
    private var savedStopsByDevice: [String: [Coordinate]] = [:]

    /// Snapshot the visible global mode + stops into the per-device
    /// dicts. Called from MainView's selectedUDID onChange just
    /// before switching, with the OLD device's UDID.
    func snapshotModeAndStops(forLeaving udid: String) {
        if let mode = activeMovementMode {
            savedModesByDevice[udid] = mode
        } else {
            savedModesByDevice.removeValue(forKey: udid)
        }
        if !pendingStops.isEmpty {
            savedStopsByDevice[udid] = pendingStops
        } else {
            savedStopsByDevice.removeValue(forKey: udid)
        }
    }

    /// Restore the per-device snapshot for the arriving device.
    /// Sets activeMovementMode first (its didSet may clear
    /// pendingStops as a side effect when moving away from
    /// .multiStop), then writes pendingStops to override the clear
    /// with the real saved staging.
    func restoreModeAndStops(forArriving udid: String) {
        let savedMode = savedModesByDevice[udid]
        let savedStops = savedStopsByDevice[udid] ?? []
        activeMovementMode = savedMode
        pendingStops = savedStops
    }

    /// Snapshot of `pendingStops` captured at the moment a multi-
    /// stop Navigate fires. Per-device (see `tripsByDevice`) so
    /// switching iPhones doesn't wipe the live waypoint dots —
    /// they reappear when you select that iPhone again.
    var activeWaypoints: [Coordinate] {
        get {
            guard let udid = selectedUDID else { return [] }
            return tripsByDevice[udid]?.waypoints ?? []
        }
        set {
            guard let udid = selectedUDID else { return }
            var t = tripsByDevice[udid] ?? ActiveTrip()
            t.waypoints = newValue
            tripsByDevice[udid] = t
        }
    }
    var lastTeleportedAt: Date?

    // MARK: - Route preview
    /// Polyline shown on the map while the user is still planning the
    /// trip — i.e., before pressing Navigate. Mirrors what the active
    /// route will look like, so the user sees the consequence of toggling
    /// straight-line mode or adding/removing stops without committing.
    var previewRoute: [Coordinate] = []
    /// Mirrors `useStraightLine` at the moment the preview was last
    /// computed, so the map renderer can pick the right style even if
    /// the user toggles the preference between refreshes.
    var previewIsStraightLine: Bool = false
    /// What the iPhone is currently *simulating* — i.e., where Maps and
    /// other apps on the phone think they are. nil means we are not
    /// simulating; phone is reporting its real GPS. Persisted via
    /// `didSet` so a relaunch can repaint the blue dot before the
    /// daemon's first state push lands.
    /// Per-device simulated location map. Each iPhone keeps its
    /// own slot — switching the sidebar selection just changes
    /// which slot the UI reads from, instead of wiping the
    /// "previous device" record (which was the v1.5 bug — A in
    /// USA, switch to B → switch back to A → A shows Taiwan
    /// because A's record was nuked on the switch-out).
    ///
    /// In-memory only. The daemon owns the durable per-device
    /// `last_lat_lng` on its `LocationService`; the Mac doesn't
    /// try to persist this dictionary across app launches.
    private(set) var simulatedLocationsByDevice: [String: Coordinate] = [:]

    /// What's-currently-displayed simulated location. Reads /
    /// writes route through `simulatedLocationsByDevice` keyed on
    /// `selectedUDID`, so:
    ///
    ///   * `state.simulatedLocation = X` writes X under the
    ///     currently-selected device — fine for the common
    ///     "teleport via the green button" path
    ///   * external code that knows the udid (event handler,
    ///     teleport/navigate handlers) should use
    ///     `setSimulatedLocation(_:for:)` so events for non-
    ///     selected devices still update their own slot
    var simulatedLocation: Coordinate? {
        get {
            guard let udid = selectedUDID,
                  udid != Self.virtualMapUDID
            else { return nil }
            return simulatedLocationsByDevice[udid]
        }
        set {
            guard let udid = selectedUDID,
                  udid != Self.virtualMapUDID
            else { return }
            let old = simulatedLocationsByDevice[udid]
            if let v = newValue {
                simulatedLocationsByDevice[udid] = v
            } else {
                simulatedLocationsByDevice.removeValue(forKey: udid)
            }
            if old != newValue {
                scheduleWeatherAndTzRefresh()
            }
        }
    }

    /// Write a simulated location for a SPECIFIC device, regardless
    /// of which is currently selected. Used by the event handler
    /// (each broadcast carries the originating udid) so a
    /// position update for the non-selected device still lands in
    /// its own slot — switching back to it shows the right pin.
    func setSimulatedLocation(_ coord: Coordinate?, for udid: String) {
        let old = simulatedLocationsByDevice[udid]
        if let c = coord {
            simulatedLocationsByDevice[udid] = c
        } else {
            simulatedLocationsByDevice.removeValue(forKey: udid)
        }
        // Only fire the chip refresh if the event was for the
        // visible device — chips show selected-device state.
        if udid == selectedUDID && old != coord {
            scheduleWeatherAndTzRefresh()
        }
    }

    // MARK: - Phone-control session (v1.7)

    /// True when AT LEAST ONE mobile-web phone-control tab is
    /// currently authenticated. v1.8 made this multi-session —
    /// multiple phones can pair independently. The lockout
    /// overlay only fires when the Mac's selected iPhone is in
    /// the controlled set below.
    var phoneSessionActive: Bool = false

    /// De-duped set of iPhone UDIDs currently being driven by
    /// some phone session. Lockout overlay fires only when
    /// `selectedUDID` is a member. Switching to a non-targeted
    /// iPhone or the Map device leaves the Mac usable.
    var controlledUDIDs: Set<String> = []

    /// When `true`, BOTH the Mac and the phone can drive at the
    /// same time — the lockout overlay is suppressed even though
    /// `phoneSessionActive` is also true. Either side can
    /// toggle, and the daemon broadcasts `event.sync_mode` so
    /// the other side flips in lockstep. Comes with a confirm
    /// dialog warning about possible state drift.
    var syncModeActive: Bool = false

    /// Per-device lockout. Lock only when:
    ///   * at least one phone session is active
    ///   * sync mode is off
    ///   * the Mac's selection is a REAL iPhone (Map device is
    ///     always usable — phones can't touch the synthetic
    ///     Map row anyway)
    ///   * the selected iPhone's UDID is in the controlled set
    ///     — i.e. some phone has actually targeted THIS device.
    ///     Phones that PIN'd but haven't acted yet don't lock
    ///     anything; the lockout activates the moment a phone
    ///     fires its first action against the device.
    var shouldShowPhoneLockout: Bool {
        guard phoneSessionActive, !syncModeActive else { return false }
        guard let sel = selectedUDID, sel != Self.virtualMapUDID else { return false }
        return controlledUDIDs.contains(sel)
    }

    /// One-shot status fetch, called once on bootstrap to seed
    /// the lockout state. Subsequent changes arrive via the
    /// `event.phone_session` broadcast in `handleEvent`.
    @MainActor
    func refreshPhoneSession() async {
        guard let client else { return }
        struct SessionReply: Decodable {
            let active: Bool
            let udids: [String]
        }
        if let reply: SessionReply = try? await client.call("phone.session", params: [:]) {
            phoneSessionActive = reply.active
            controlledUDIDs = Set(reply.udids)
        }
        struct SyncReply: Decodable { let sync: Bool }
        if let reply: SyncReply = try? await client.call("phone.sync_mode", params: [:]) {
            syncModeActive = reply.sync
        }
    }

    /// Toggle the simultaneous-control "sync mode" flag. Mac UI
    /// surfaces this via a button on the lockout overlay; the
    /// daemon's broadcast ensures the phone tab sees the same
    /// state on its next /state poll.
    @MainActor
    func setSyncMode(_ on: Bool) async {
        guard let client else { return }
        _ = try? await client.callRaw("phone.set_sync_mode", params: [
            "sync": AnyCodable(on),
        ])
        syncModeActive = on
    }

    /// Force-revoke the phone session — rotates the daemon's
    /// PIN + token, broadcasts `event.phone_session(active=false)`.
    /// Triggered by the "停止手機端" button on the lockout overlay.
    @MainActor
    func forcePhoneLogout() async {
        guard let client else { return }
        _ = try? await client.callRaw("phone.force_logout")
        // Mirror locally — the broadcast also flips this, but
        // doing it eagerly stops the overlay from lingering for
        // the half-second of round-trip latency.
        phoneSessionActive = false
    }

    /// Browse-only "what point am I looking at" cursor. Set ONLY
    /// by map clicks while the virtual Map device is selected; the
    /// real-iPhone code paths never touch it. Transient — we do
    /// not persist it, so reopening the app starts with a clean
    /// browse cursor (and a clean simulated location).
    ///
    /// Why separate from `simulatedLocation`?
    ///
    ///   Before v1.5 a browse-mode click overwrote
    ///   `simulatedLocation`, which then got persisted to
    ///   `AppPreferences` and restored on next launch. The bug:
    ///   click Tokyo in browse mode → connect iPhone → green
    ///   pin shows at Tokyo with "iPhone (simulated)" label,
    ///   even though the iPhone's real spoofed GPS is somewhere
    ///   else entirely. Separating the two concepts lets the
    ///   status-bar chip / recenter button / map pin pick the
    ///   right source via `currentMapFocus` without contamination.
    var browseCursor: Coordinate? {
        didSet { scheduleWeatherAndTzRefresh() }
    }

    /// What point should the status-bar chips, map pin, and
    /// recenter button focus on right now?
    ///
    ///   * Virtual Map device selected → browse cursor (the last
    ///     point the user clicked while just looking)
    ///   * Real iPhone selected → simulated location (what the
    ///     iPhone *itself* thinks its GPS is)
    ///
    /// Computed, not stored, so it always reflects the freshest
    /// values of both inputs.
    var currentMapFocus: Coordinate? {
        if isVirtualMapSelected { return browseCursor }
        return simulatedLocation
    }

    /// True while ANY mode that actively moves the iPhone is
    /// running. Used by the MainView .onChange handler on
    /// `simulatedLocation` to decide whether to keep the map's
    /// camera centred on the moving puck. Gold-Ditto doesn't
    /// move; multi-stop staging without an active Navigate
    /// doesn't move; the map only chases motion that's actually
    /// happening.
    ///
    /// v1.11.0 hotfix: user-toggleable. When `mapAutoRecenter` is off,
    /// continuous follow is suppressed entirely — explicit one-shot
    /// teleports (route start, Recent Places "Show on map", manual
    /// recenter button) still pan because those go through
    /// `pendingMapFly` directly, not this getter.
    var shouldFollowSimulatedLocation: Bool {
        guard mapAutoRecenter else { return false }
        if navigation != nil { return true }
        switch activeMovementMode {
        case .joystick, .randomWalk: return true
        case .multiStop, .goldDitto, .none: return false
        }
    }

    /// User-controlled toggle: when on, the map auto-recenters every
    /// 1 Hz position tick during joystick / random walk / navigation;
    /// when off, the map stays where the user left it and they
    /// recenter manually via the "Show current location" button or by
    /// panning. One-shot teleports (route-start fly, Recent Places,
    /// preset Teleport) ignore this setting — they always pan.
    /// Persisted to UserDefaults so the preference survives launches.
    var mapAutoRecenter: Bool = {
        if UserDefaults.standard.object(forKey: "map.autoRecenter") == nil {
            return true  // default behaviour preserves the existing UX
        }
        return UserDefaults.standard.bool(forKey: "map.autoRecenter")
    }() {
        didSet { UserDefaults.standard.set(mapAutoRecenter, forKey: "map.autoRecenter") }
    }

    // MARK: - Status bar A: weather + remote-timezone for the simulated location

    /// Open-Meteo current-conditions snapshot for the simulated puck.
    /// nil while we haven't fetched yet OR when there is no simulation
    /// active (status bar shows a "—" placeholder in both cases).
    var currentWeather: WeatherService.Snapshot?
    /// Apple-reverse-geocoded context for the simulated puck — TZ +
    /// ISO country + localised country name. Same nil-semantics as
    /// `currentWeather`. Computed in one CLGeocoder round-trip per
    /// significant move; the status bar's country chip and remote-
    /// time chip both read from it.
    var simulatedGeoContext: TimezoneService.GeoContext?
    /// Convenience getter so existing TopStatusBar code that asked
    /// for `simulatedTimeZone` keeps working without an outright
    /// rename.
    var simulatedTimeZone: TimeZone? { simulatedGeoContext?.timezone }
    /// Coalesces rapid teleports into one fetch — set on every change
    /// of `simulatedLocation`, cancelled before each new schedule.
    ///
    /// `@ObservationIgnored` because this is internal task plumbing
    /// that no view should ever observe. Without the attribute the
    /// `@Observable` macro generates an access hook on every read,
    /// and a high-frequency caller (e.g. map-pan during phone
    /// teleport) can corrupt the observation registrar's internal
    /// access list and crash. See v1.9.3 fix notes near
    /// `saveMapCamera`.
    @ObservationIgnored private var weatherRefreshTask: Task<Void, Never>?

    /// Cancel any in-flight weather/tz fetch and start a new one for
    /// the current `simulatedLocation`. Debounced ~1 s so a multi-stop
    /// navigation that updates the puck on every tick doesn't hammer
    /// Open-Meteo.
    private func scheduleWeatherAndTzRefresh() {
        weatherRefreshTask?.cancel()
        // Source the coord from `currentMapFocus`, which auto-picks
        // browseCursor vs simulatedLocation based on selectedUDID.
        guard let coord = currentMapFocus else {
            currentWeather = nil
            simulatedGeoContext = nil
            return
        }
        // Snapshot the latest coord so the closure doesn't read a
        // stale `simulatedLocation` if the user teleports again
        // while the previous fetch is still mid-flight.
        let target = coord
        weatherRefreshTask = Task { [weak self] in
            // Short coalescing window — under a second so the
            // chip updates feel responsive, but long enough that a
            // multi-stop nav firing per-tick position updates
            // doesn't hammer Open-Meteo.
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            // Fire weather + geo-context in parallel; both are
            // best-effort. We log failures because the user
            // reported the chips not populating — silent failure
            // here would make that very hard to diagnose.
            async let snap: WeatherService.Snapshot? = {
                do {
                    return try await WeatherService.fetch(
                        lat: target.lat, lng: target.lng,
                    )
                } catch {
                    NSLog("LociiGhost: weather fetch failed: %@",
                          String(describing: error))
                    return nil
                }
            }()
            async let ctx: TimezoneService.GeoContext = TimezoneService.context(
                forLat: target.lat, lng: target.lng,
            )
            let (s, c) = await (snap, ctx)
            if Task.isCancelled { return }
            if c.isoCountryCode == nil {
                NSLog("LociiGhost: reverse geocode returned no country for %f,%f",
                      target.lat, target.lng)
            }
            await MainActor.run {
                self?.currentWeather = s
                self?.simulatedGeoContext = c
            }
        }
    }

    /// One-shot manual refresh for the status-bar refresh button.
    /// Keeps the weather chip live when the user is parked at a
    /// single simulated location for a long time.
    @MainActor
    func refreshWeatherAndTzNow() {
        scheduleWeatherAndTzRefresh()
    }

    // MARK: - Navigation
    /// Travel profile + matching default speed for the next Navigate click.
    /// `didSet` persists immediately so the user's last choice survives
    /// a relaunch.
    var travelProfile: TravelProfile = .driving {
        didSet { persistRoutingPrefs() }
    }
    /// Override speed in m/s. nil means "use the profile default".
    var customSpeedMps: Double? {
        didSet { persistRoutingPrefs() }
    }
    /// When true, the next Navigate skips OSRM and walks the iPhone
    /// straight-line between consecutive stops. Cannot be toggled mid-
    /// navigation — the route was already computed; if you want to
    /// switch, Stop, flip this, then Navigate again.
    /// (Same `_modify` caveat as `pendingStops` — preview refresh is
    /// driven from the view layer via `.onChange`.)
    var useStraightLine: Bool = false
    /// How many times to walk the route on the next Navigate. 1 = a
    /// single trip; 2+ closes the route into a loop and repeats the
    /// closed loop N times. Persists like `travelProfile` so a
    /// previously-set value survives clearing/restoring stops.
    var routeLaps: Int = 1
    /// Live navigation snapshot from the daemon. Updated via
    /// `event.position_update` and `event.state_changed`. Becomes nil when
    /// navigation finishes (reached / stopped) but `activeRoute` keeps the
    /// last route + destination visible on the map.
    var navigation: NavigationVM? {
        didSet {
            // Guard: only write navigationActive when the nil/non-nil
            // state actually changes. @Observable fires withMutation on
            // every assign — without this guard, navigation = nav on
            // every 1 Hz position event re-notifies all observers of
            // navigationActive even when it's already true, causing
            // MovementModesSection / ControlPanel / StartRouteSheet to
            // re-render every second.
            let active = navigation != nil
            if navigationActive != active { navigationActive = active }
            let paused = navigation?.isPaused == true
            if navigationPaused != paused { navigationPaused = paused }
        }
    }

    /// Lightweight session-active flags — set to `true` when a session
    /// starts, `false` when it stops. Views that only need to know
    /// "is something running?" (mode buttons, alert gates, etc.) should
    /// read these instead of `navigation != nil` / `randomWalk != nil` /
    /// `joystick != nil`. The full VMs are rebuilt on every 1 Hz position
    /// event; anything observing those properties re-renders every second.
    /// These flags only change on session transitions, so sidebar views
    /// that read them stay completely quiet while a simulation is running.
    var navigationActive: Bool = false
    var navigationPaused: Bool = false
    var randomWalkActive: Bool = false
    var joystickActive: Bool = false

    /// Convenience: any session is running. Reads only the three cheap
    /// booleans above, not the full VMs.
    var anySessionActive: Bool { navigationActive || randomWalkActive || joystickActive }

    /// True when a left-click (or right-click "Add as stop") on the map
    /// should append a coordinate to the pending-stops queue.
    ///
    /// Two windows:
    ///   1. Multi-stop mode is the active panel — the normal staging phase
    ///      before the user presses Navigate.
    ///   2. A multi-stop dwell navigation is already running — `pendingStops`
    ///      is non-empty (not cleared by navigate()) and we have a live
    ///      `dwellContext` that can absorb extra stops mid-trip.
    ///
    /// Deliberately excludes non-dwell navigation: once the daemon has the
    /// full fixed polyline there's nowhere to inject a new waypoint without
    /// re-routing. The stop is staged in `pendingStops` by `appendQueueStop`
    /// and stays there for the next Navigate after the current trip ends.
    var canQueueStop: Bool {
        if activeMovementMode == .multiStop { return true }
        if navigationActive && !pendingStops.isEmpty { return true }
        return false
    }

    /// Append `coord` to the staging queue.
    func appendQueueStop(_ coord: Coordinate) {
        pendingStops.append(coord)
    }

    /// Set by `runRoute` when the user requested looping, cleared by
    /// `stopNavigation` (explicit Stop) or by the loop counter
    /// reaching zero in `applyStateEvent`. When a navigation reaches
    /// "idle" naturally with this populated, the event handler
    /// teleports back to `routePoints[0]` and fires another navigate
    /// — that's the actual "loop" mechanism (the daemon plays each
    /// lap as a single trip).
    private var loopContext: LoopContext?

    /// Active dwell-mode sequence. Legacy — no longer set by navigate();
    /// the new DwellMonitor approach handles per-stop pausing. Kept to
    /// avoid breaking the applyStateEvent dead-code blocks below until
    /// they are cleaned up in a future pass.
    private var dwellContext: DwellContext?

    /// Multi-stop lap context. Set when routeLaps > 1 and multi-stop
    /// Navigate is pressed. On natural idle, applyStateEvent decrements
    /// remainingLaps and fires teleport + navigate for the next lap,
    /// matching the same pattern as loopContext for route replay.
    private var multiStopLapContext: MultiStopLapContext?

    /// Position-based dwell monitor. The full multi-stop trip runs as ONE
    /// navigate RPC; this monitor injects pause/resume at each staged stop.
    /// Cleared by Stop, mode switch, or all-stops-visited.
    var dwellMonitor: DwellMonitor? = nil

    /// Per-stop dwell mode (v1.11.0 Feat #3). When true, multi-stop
    /// Navigate pauses the iPhone for `dwellSeconds` at each waypoint
    /// without changing the route plan. UserDefaults persists across launches.
    var dwellEnabled: Bool = UserDefaults.standard.bool(forKey: "dwell.enabled") {
        didSet { UserDefaults.standard.set(dwellEnabled, forKey: "dwell.enabled") }
    }
    /// Seconds to dwell at each stop when `dwellEnabled` is true.
    /// Clamped to a minimum of 1 because zero defeats the purpose
    /// (it's equivalent to dwellEnabled = false).
    var dwellSeconds: Int = max(1, UserDefaults.standard.integer(forKey: "dwell.seconds")) {
        didSet { UserDefaults.standard.set(max(1, dwellSeconds), forKey: "dwell.seconds") }
    }
    /// Bookmark sidebar sort order ("date" / "alpha" / "manual").
    /// Kept in AppState rather than @AppStorage to avoid the macOS
    /// global UserDefaults.didChangeNotification re-render trap that
    /// would cause BookmarksSection to redraw on every system write.
    var bookmarkSortMode: String = UserDefaults.standard.string(forKey: "bookmarks.sortMode") ?? "date" {
        didSet {
            guard bookmarkSortMode != oldValue else { return }
            UserDefaults.standard.set(bookmarkSortMode, forKey: "bookmarks.sortMode")
        }
    }

    /// User dismissed the on-map ControlPanel popup (via its X
    /// button). When true, the popup is hidden and a floating chip
    /// + a sidebar "Show route controls" button take over as the
    /// re-open entry points. Cleared automatically when pendingStops
    /// empties — the next planning session shows the panel by default.
    var navigationControlsHidden: Bool = false

    /// The most recent navigation's full route polyline. Persists across
    /// pause / stop / arrival so the user can still see where they were
    /// going. Cleared explicitly by Restore, by starting a new navigation,
    /// or by Teleport.
    // ── Per-device active trip state ──────────────────────────
    // Each iPhone keeps its own slot for the route polyline +
    // destination + straight-line flag + waypoint stops. The
    // `active*` properties below are COMPUTED getters that
    // read whichever device is currently selected — so
    // switching the sidebar selection from iPhone A (running a
    // multi-stop nav) to iPhone B and back to A restores A's
    // entire trip drawing instead of wiping it.
    private struct ActiveTrip {
        var route: [Coordinate]? = nil
        var destination: Coordinate? = nil
        var isStraightLine: Bool = false
        var waypoints: [Coordinate] = []
    }
    private var tripsByDevice: [String: ActiveTrip] = [:]

    var activeRoute: [Coordinate]? {
        get {
            guard let udid = selectedUDID else { return nil }
            return tripsByDevice[udid]?.route
        }
        set {
            guard let udid = selectedUDID else { return }
            var t = tripsByDevice[udid] ?? ActiveTrip()
            t.route = newValue
            tripsByDevice[udid] = t
        }
    }
    /// Last point of `activeRoute`, kept as a separate field so the map can
    /// draw the destination flag without scanning the route every refresh.
    var activeDestination: Coordinate? {
        get {
            guard let udid = selectedUDID else { return nil }
            return tripsByDevice[udid]?.destination
        }
        set {
            guard let udid = selectedUDID else { return }
            var t = tripsByDevice[udid] ?? ActiveTrip()
            t.destination = newValue
            tripsByDevice[udid] = t
        }
    }
    /// True when `activeRoute` was generated by the daemon's straight-line
    /// mode (no OSRM lookup). The map renderer reads this to draw the
    /// polyline dashed instead of solid, so the visual style itself
    /// confirms the mode.
    var activeRouteIsStraightLine: Bool {
        get {
            guard let udid = selectedUDID else { return false }
            return tripsByDevice[udid]?.isStraightLine ?? false
        }
        set {
            guard let udid = selectedUDID else { return }
            var t = tripsByDevice[udid] ?? ActiveTrip()
            t.isStraightLine = newValue
            tripsByDevice[udid] = t
        }
    }

    /// Write trip fields for a specific UDID (used by code
    /// paths like `navigate(udid:)` that know the target
    /// regardless of current selection — same pattern as
    /// `setSimulatedLocation(_:for:)`).
    func setActiveTrip(
        route: [Coordinate]?,
        destination: Coordinate?,
        isStraightLine: Bool,
        waypoints: [Coordinate],
        for udid: String,
    ) {
        var t = tripsByDevice[udid] ?? ActiveTrip()
        t.route = route
        t.destination = destination
        t.isStraightLine = isStraightLine
        t.waypoints = waypoints
        tripsByDevice[udid] = t
    }
    func clearActiveTrip(for udid: String) {
        tripsByDevice.removeValue(forKey: udid)
    }

    // MARK: - Map fly requests
    /// One-shot map-recenter request from search results, "Show on map"
    /// buttons, etc. Each new request gets a fresh UUID; the map view's
    /// coordinator remembers the last id it serviced and ignores
    /// duplicates so updateNSView() stays idempotent.
    var pendingMapFly: MapFlyRequest?

    /// v1.11.2: when the user previews a search result (search bar →
    /// preview button), drop a marker at the previewed coord so the
    /// user actually *sees* where they searched. Cleared automatically
    /// when teleport / navigate fires (a simulated or destination pin
    /// then takes the visual focus) or when the user previews another
    /// place (the marker just relocates). MapContainerView renders
    /// this via a dedicated SearchPreviewAnnotation type.
    var searchPreviewCoord: Coordinate?

    /// Currently selected base map layer. Mutated from the floating
    /// layer-selector button; MapContainerView observes this and
    /// swaps overlays in updateNSView(). Default is Apple's native
    /// vector map — it's the lowest-energy option (no tile downloads,
    /// Apple-optimised Metal renderer) and matches what most macOS
    /// users see in Maps.app.
    var mapTileLayer: MapTileLayer = .appleStandard

    // MARK: - Mac proxy location
    let macLocation = LocationProxyService()

    // MARK: - Privilege state
    /// True if the connected daemon is running as root (set after a
    /// successful daemon.info call). False means we'll fail at the
    /// utun step on Connect; the GUI should surface an admin prompt.
    /// nil = haven't asked yet.
    var daemonIsRoot: Bool?
    /// Sticky flag set when a Connect attempt fails with TUNNEL_FAILED.
    /// Lets the BottomBar / banner offer "Authenticate as admin" until
    /// the next successful elevation or Restore.
    var needsAdminElevation: Bool = false
    /// True while `requestAdminElevation()` is in flight — the auth
    /// dialog is up or the daemon is still spawning.
    var isElevating: Bool = false

    // MARK: - WiFi pairing + IP-direct connect (Phase 4.5)
    /// Latest set of iPhones the daemon found on the LAN via mDNS or
    /// /24 TCP scan. `nil` until `discoverWiFi()` runs once. Each entry
    /// is `(ip, port, name, method)` — UDID is unknown until the actual
    /// pair-verify in `connectWiFiByIP` resolves it.
    var wifiCandidates: [WiFiCandidate]?
    /// True while a `wifi.repair`, `wifi.discover`, or `wifi.connect_ip`
    /// RPC is in flight, so the UI can disable buttons + show spinners.
    var isPairingForWiFi: Bool = false
    var isDiscoveringWiFi: Bool = false
    var isConnectingWiFiByIP: Bool = false
    /// Live two-stage pair-progress, populated from
    /// `event.wifi_pair_progress` while `pairForWiFi()` runs. nil
    /// outside of an active pair operation. The GUI uses `.fraction`
    /// for a determinate ProgressView and `.message` for the
    /// "Step 1/2: tap Trust on iPhone" label.
    var pairProgress: PairProgress?
    /// When non-nil, the WiFi-connect selection sheet is open for the
    /// given device. Set by `openWiFiConnectFlow(udid:)` (which the
    /// Connect-via-WiFi button hooks into); the sheet itself owns the
    /// dismiss and clears this back to nil. Letting AppState own the
    /// presentation makes auto-discover-on-open trivial: the sheet
    /// kicks off `discoverWiFi()` on appear and the existing
    /// observable bindings paint the result.
    var wifiConnectSheet: WiFiConnectSheetTarget?

    // MARK: - Phone control (Phase 5.2)
    /// LAN URL + PIN for the daemon's phone-control HTTP server.
    /// Populated by `fetchPhoneControlInfo()`; sheet renders these
    /// for the user to type into their phone browser. The endpoint
    /// is localhost-only on the daemon side, so this info is never
    /// exposed to the LAN — only the desktop GUI can fetch it.
    var phoneControlInfo: PhoneControlInfo?
    var isLoadingPhoneInfo: Bool = false
    /// Drives the phone-control sheet presentation.
    var showPhoneControlSheet: Bool = false

    // MARK: - Movement modes (Phase 3)
    /// Latest snapshot from a `location.random_walk` session, populated
    /// from `event.position_update` / `event.state_changed` notifications.
    /// nil means no walker is running.
    var randomWalk: RandomWalkVM? {
        didSet {
            let active = randomWalk != nil
            if randomWalkActive != active { randomWalkActive = active }
        }
    }
    /// Latest snapshot from a `location.joystick` session.
    var joystick: JoystickVM? {
        didSet {
            let active = joystick != nil
            if joystickActive != active { joystickActive = active }
        }
    }

    /// Live preview of the random-walk bounds while the user is still
    /// configuring the panel. The map renders a translucent disc using
    /// these values so the user can see exactly which area the iPhone
    /// will wander before they press Start. Cleared as soon as the
    /// panel goes away, or once a real walker is running (the actual
    /// motion is its own visual story).
    var randomWalkPreviewCenter: Coordinate?
    var randomWalkPreviewRadiusM: Double?

    // MARK: - Bookmarks (Phase 5.3)
    /// When non-nil, the BookmarkEditSheet pops up to let the user
    /// name + categorise + pick an icon for a new bookmark at this
    /// coordinate. Set by the map's right-click "Save as bookmark…"
    /// menu item; sheet clears it on Cancel / Save.
    var pendingBookmarkCoord: Coordinate?
    /// When set, BookmarkEditSheet opens in EDIT mode for an
    /// existing bookmark instead of creating a new one. Mutually
    /// exclusive with `pendingBookmarkCoord` in practice.
    var editingBookmark: Bookmark?

    /// When set, RouteEditSheet opens in CREATE mode with these
    /// imported coordinates. Cleared by the sheet on save / cancel.
    /// Set by `importGPX()` after a successful parse — the sheet then
    /// asks the user for a name and category before persisting.
    var pendingRouteImport: PendingRouteImport?
    /// EDIT-mode counterpart for an already-saved Route. Mutually
    /// exclusive with `pendingRouteImport` in practice.
    var editingRoute: Route?

    /// v1.11.2: dedicated edit-waypoints sheet trigger. Separate from
    /// `editingRoute` (which surfaces RouteEditSheet for name /
    /// category / icon) so a user can edit metadata or waypoints
    /// independently without one sheet trying to host both UIs.
    var editingRouteWaypoints: Route?

    /// "Save current pending stops as a route" surfaces the same
    /// `RouteEditSheet` that GPX import uses. We pre-fill the name
    /// suggestion to a friendly default so the user just picks a
    /// category + icon and hits Save. Only the AppState method
    /// `stagePendingStopsAsRoute()` should write to this field.
    func stagePendingStopsAsRoute() {
        guard !pendingStops.isEmpty else { return }
        let suggested = String(
            format: String(
                localized: "Custom route (%lld stops)",
                comment: "Default name pre-filled in the RouteEditSheet when staging from pendingStops",
            ),
            pendingStops.count,
        )
        pendingRouteImport = PendingRouteImport(
            suggestedName: suggested,
            coordinates: pendingStops,
        )
    }

    /// When set, the main view shows a confirmation alert: "Start this
    /// route?" Picking the saved Route from the sidebar parks itself
    /// here instead of running immediately so a stray click doesn't
    /// hijack a navigation the user is mid-stream on.
    var routePendingConfirm: Route?

    // MARK: - Stop presets (v1.11.0 — multi-stop "favourites")
    //
    // Save the current `pendingStops` as a named preset so the user
    // can recall the same staging next session. Distinct from `Route`
    // — see `StopPreset.swift` for the rationale. Click flow differs
    // too: a preset opens `LoadStopPresetSheet` (Cancel / Display /
    // Execute) instead of `Route`'s direct-run sheet.

    /// Non-nil while the SavePresetSheet is up. Cleared by the sheet
    /// on Cancel / Save.
    var presetPendingSave: Bool = false

    /// Non-nil while the LoadPresetSheet is up — clicking a preset
    /// row parks the chosen entity here instead of running anything
    /// immediately, just like `routePendingConfirm`.
    var presetPendingLoad: StopPreset?

    /// Save the current `pendingStops` as a new `StopPreset` with
    /// the user-provided name. Empty name or empty stops both no-op
    /// — the caller (SavePresetSheet) gates on these but a defensive
    /// guard here keeps the storage clean.
    @MainActor
    func saveCurrentStopsAsPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !pendingStops.isEmpty,
              let ctx = modelContext else { return }
        let preset = StopPreset(name: trimmed, coordinates: pendingStops)
        ctx.insert(preset)
        try? ctx.save()
    }

    /// Load a saved preset back into `pendingStops`. The caller
    /// (LoadStopPresetSheet) decides whether to also teleport the
    /// iPhone to the first coordinate via the `teleport` flag.
    ///
    /// * `teleport == false` → just stage the coords + map-show them,
    ///   user can inspect / re-arrange before pressing Navigate.
    /// * `teleport == true` → stage the coords, then teleport the
    ///   currently-selected iPhone to the first one. Like the start
    ///   of `runRoute` minus the actual navigate; user still has to
    ///   press Navigate to start moving.
    @MainActor
    func loadStopPreset(_ preset: StopPreset, teleport: Bool) async {
        let coords = preset.coordinates
        guard !coords.isEmpty else { return }
        // Switch the user to Multi-Stop mode if they aren't already,
        // so the staged stops are immediately visible in the right
        // sidebar panel.
        activeMovementMode = .multiStop
        pendingStops = coords
        if teleport,
           let udid = selectedUDID,
           devices.first(where: { $0.udid == udid })?.connected == true,
           let first = coords.first {
            await self.teleport(udid: udid, lat: first.lat, lng: first.lng)
            // teleport clears `pendingStops` as part of its single-action
            // reset — restore them right after so the staging list the
            // user just loaded survives the teleport.
            pendingStops = coords
        }
        // Re-centre map on the first coord so the user immediately
        // sees where the preset is regardless of teleport mode.
        if let first = coords.first {
            pendingMapFly = MapFlyRequest(
                coordinate: first,
                spanMeters: 2_000,
            )
        }
    }

    /// Delete a saved preset. Defensive — caller (preset row context
    /// menu) is the only path.
    @MainActor
    func deleteStopPreset(_ preset: StopPreset) {
        guard let ctx = modelContext else { return }
        ctx.delete(preset)
        try? ctx.save()
    }

    // MARK: - Internals
    //
    // Every property below is `@ObservationIgnored` — they're
    // implementation plumbing (daemon clients, in-flight tasks,
    // SwiftData handles) that no view should ever observe. Without
    // the attribute the `@Observable` macro generates per-access
    // hooks; high-frequency callers (map-pan during phone teleport
    // calling `saveMapCamera`, which reads `modelContext`) can
    // corrupt the observation registrar's `_AccessList` and crash
    // the app with EXC_BAD_ACCESS inside `addAccess`. See v1.9.3
    // crash diagnosis.
    @ObservationIgnored private var lifecycle: DaemonLifecycle?
    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    // MARK: - Persistence (Phase 5.2 — SwiftData)

    /// SwiftData context, attached at app launch by LociiGhostApp.
    /// nil before attach (early bootstrap calls just no-op the
    /// persistence read/writes; the in-memory defaults still work).
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var preferences: AppPreferences?

    /// Called from LociiGhostApp.task right before bootstrap so we
    /// can hydrate AppState from disk before the daemon connects.
    /// Idempotent — safe to call again on a hot reload.
    func attachModelContext(_ ctx: ModelContext) {
        modelContext = ctx
        let prefs = AppPreferences.fetchOrCreate(ctx)
        preferences = prefs
        // Hydrate transient AppState fields from the persisted
        // record so the UI repaints with the user's last choices
        // before the daemon is even up.
        if let raw = TravelProfile(rawValue: prefs.travelProfileRaw) {
            travelProfile = raw
        }
        customSpeedMps = prefs.customSpeedMps

        // v1.9.3 stored-property prefs: copy the three settings-sheet
        // values out of SwiftData into the observable mirrors. The
        // didSet guards on `isHydratingPreferences` skip the
        // redundant write-back-to-disk that would otherwise fire here.
        isHydratingPreferences = true
        alertSoundEnabled = prefs.alertSoundEnabled
        googleGeocodeAPIKey = prefs.googleGeocodeAPIKey
        routingEngine = RoutingEngine(rawValue: prefs.routingEngineRaw) ?? .osrmDemo
        appearanceMode = AppearanceMode(rawValue: prefs.appearanceModeRaw) ?? .brand
        isHydratingPreferences = false
        // NOTE: We deliberately do NOT restore simulatedLocation
        // from `prefs.lastSimulatedLat/Lng` on launch — that
        // persisted blob had no record of which iPhone produced
        // it. As of v1.6 simulated locations live in the
        // `simulatedLocationsByDevice` dict, populated lazily
        // from daemon `event.position_update` broadcasts (each
        // event carries the originating udid).
        scheduleWeatherAndTzRefresh()
    }

    /// The last persisted map camera (or nil if we never saved one).
    /// MapContainerView reads this on first appear so the map opens
    /// where the user left it.
    var savedMapCamera: (center: Coordinate, spanMeters: Double)? {
        guard let p = preferences,
              let lat = p.mapCenterLat,
              let lng = p.mapCenterLng,
              let span = p.mapSpanMeters
        else { return nil }
        return (Coordinate(lat: lat, lng: lng), span)
    }

    /// Called by MapContainerView when the user pans / zooms. Throttled
    /// upstream so we don't write to disk on every pixel of movement.
    func saveMapCamera(centerLat: Double, centerLng: Double, spanMeters: Double) {
        guard let p = preferences else { return }
        p.mapCenterLat = centerLat
        p.mapCenterLng = centerLng
        p.mapSpanMeters = spanMeters
        try? modelContext?.save()
    }

    /// Persist whatever the SwiftUI state currently is. Called from
    /// the property accessors that already mutate AppState — keeps
    /// preference disk-state aligned without us scattering save calls
    /// over every random place that touches travelProfile etc.
    func persistRoutingPrefs() {
        guard let p = preferences else { return }
        p.travelProfileRaw = travelProfile.rawValue
        p.customSpeedMps = customSpeedMps
        try? modelContext?.save()
    }
    func persistLastSimulated() {
        guard let p = preferences else { return }
        p.lastSimulatedLat = simulatedLocation?.lat
        p.lastSimulatedLng = simulatedLocation?.lng
        try? modelContext?.save()
    }

    // MARK: - Settings-page state (v1.9 → v1.9.3 stored-property refactor)

    /// True while `attachModelContext` is copying values from the
    /// SwiftData prefs row into the stored properties below — set
    /// before the first assignment, cleared after the last. Each
    /// of the three preference properties checks this in didSet so
    /// it doesn't write the just-loaded value straight back to disk
    /// (and trigger a redundant `modelContext.save()`).
    @ObservationIgnored private var isHydratingPreferences = false

    /// Toggle controlled from the Settings sheet. When ON, the
    /// route-completion event handler plays the macOS system alert
    /// sound. Persisted to disk through AppPreferences.
    ///
    /// v1.9.3: changed from a computed property (which read/wrote
    /// `preferences?.alertSoundEnabled`) to a stored property with
    /// didSet. The `@Observable` macro generates proper observation
    /// hooks for stored properties; computed properties that proxy
    /// to a foreign SwiftData @Model produced unstable observation
    /// tracking that triggered SwiftUI `_AccessList.addAccess`
    /// crashes during high-frequency view updates. Stored property
    /// + didSet keeps disk persistence one-way.
    var alertSoundEnabled: Bool = false {
        didSet {
            guard !isHydratingPreferences else { return }
            preferences?.alertSoundEnabled = alertSoundEnabled
            try? modelContext?.save()
        }
    }

    /// User-supplied Google Geocoding API key. Set from Settings.
    /// `nil` (or whitespace-only) means "no key configured" — the
    /// geocoder fallback is then bypassed. Stored property pattern
    /// matches alertSoundEnabled above (see its doc-comment for why).
    var googleGeocodeAPIKey: String? = nil {
        didSet {
            guard !isHydratingPreferences else { return }
            // Trim before persisting so a key with trailing
            // whitespace doesn't fail Google's API auth check on
            // first use. The in-memory value keeps the raw user
            // input so the Settings field doesn't visually lurch
            // while they're editing.
            let trimmed = googleGeocodeAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            preferences?.googleGeocodeAPIKey =
                (trimmed?.isEmpty == false) ? trimmed : nil
            try? modelContext?.save()
        }
    }

    /// Which routing backend the daemon should use. Default is the
    /// public OSRM demo (the original behaviour). Switching to
    /// `.google` requires `googleGeocodeAPIKey` to be set; switching
    /// to `.straightLine` overrides any `useStraightLine` toggle in
    /// the UI by always routing in straight lines.
    var routingEngine: RoutingEngine = .osrmDemo {
        didSet {
            guard !isHydratingPreferences else { return }
            preferences?.routingEngineRaw = routingEngine.rawValue
            try? modelContext?.save()
        }
    }

    /// v1.9.4: brand vs system appearance tint. `.brand` (default)
    /// uses the LociiGhost sage palette from the AppIcon; `.system`
    /// uses macOS's default accent. The WindowGroup root reads this
    /// to set `Environment(\.tint)`, so changes propagate live
    /// without an app relaunch.
    var appearanceMode: AppearanceMode = .brand {
        didSet {
            guard !isHydratingPreferences else { return }
            preferences?.appearanceModeRaw = appearanceMode.rawValue
            try? modelContext?.save()
        }
    }

    // MARK: - Bookmarks (Phase 5.3)

    /// Add a new bookmark. The sidebar's `@Query<Bookmark>` re-runs
    /// automatically on insert, so the new entry appears without
    /// further plumbing.
    func addBookmark(name: String, lat: Double, lng: Double,
                     category: String = "",
                     iconSymbol: String = "mappin.circle.fill") {
        guard let ctx = modelContext else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameToSave = trimmed.isEmpty
            ? String(format: "(%.5f, %.5f)", lat, lng)
            : trimmed
        let bm = Bookmark(name: nameToSave, lat: lat, lng: lng,
                          category: category.trimmingCharacters(in: .whitespaces),
                          iconSymbol: iconSymbol)
        ctx.insert(bm)
        try? ctx.save()
    }

    /// Delete a bookmark. Save explicitly so the on-disk store
    /// reflects the deletion immediately — relying on SwiftData's
    /// debounced auto-save means a quick app quit could lose it.
    func deleteBookmark(_ bm: Bookmark) {
        guard let ctx = modelContext else { return }
        ctx.delete(bm)
        try? ctx.save()
    }

    /// Rename / re-categorise / re-icon. Phase 5.3 keeps the edit
    /// affordance simple — one method, all fields optional.
    func updateBookmark(_ bm: Bookmark,
                        name: String? = nil,
                        category: String? = nil,
                        iconSymbol: String? = nil) {
        guard let ctx = modelContext else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { bm.name = trimmed }
        }
        if let category {
            bm.category = category.trimmingCharacters(in: .whitespaces)
        }
        if let iconSymbol, !iconSymbol.isEmpty {
            bm.iconSymbol = iconSymbol
        }
        try? ctx.save()
    }

    // MARK: - Recent Places (v1.9 — history capsule on map)

    /// Hard cap on persisted RecentPlace rows. The popover renders a
    /// scroll-less list, so the cap also bounds the visual height —
    /// 50 fits "stuff I jumped to in the last week" without ever
    /// needing the user to wade through hundreds of entries. We prune
    /// the oldest beyond this on every insert.
    private static let recentPlacesCap = 50

    /// Fetch the latest N recent-place rows, newest first. Returns []
    /// before the model context is attached (early bootstrap path).
    /// Use this from views that need a live list — they should NOT
    /// use `@Query` directly, because we want explicit sort order +
    /// prune behaviour driven through AppState.
    func fetchRecentPlaces(limit: Int = 30) -> [RecentPlace] {
        guard let ctx = modelContext else { return [] }
        var descriptor = FetchDescriptor<RecentPlace>(
            sortBy: [SortDescriptor(\RecentPlace.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? ctx.fetch(descriptor)) ?? []
    }

    /// Insert a new entry into the recent-places log. De-dupes against
    /// the most recent entry: rapid double-teleport to the same coord
    /// (e.g. search → teleport then map-click teleport) doesn't create
    /// two adjacent rows. Prunes older rows past the cap.
    ///
    /// Called from teleport / navigate / search action paths. Cheap —
    /// one insert + at most one delete every 50 calls.
    func recordRecentPlace(label: String, lat: Double, lng: Double, kind: RecentPlace.Kind) {
        guard let ctx = modelContext else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = trimmed.isEmpty
            ? String(format: "%.5f, %.5f", lat, lng)
            : trimmed

        // De-dupe with the most-recent row when label + coord match
        // (rounded to ~11m so floating-point noise from the daemon's
        // re-projected coord doesn't make duplicates). Kind also
        // has to match — teleport then navigate to the same place is
        // two intentional actions and shouldn't collapse.
        var descriptor = FetchDescriptor<RecentPlace>(
            sortBy: [SortDescriptor(\RecentPlace.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let last = (try? ctx.fetch(descriptor))?.first,
           last.kindRaw == kind.rawValue,
           last.label == displayLabel,
           abs(last.lat - lat) < 1e-4,
           abs(last.lng - lng) < 1e-4 {
            // Bump the timestamp so the row floats back to the top
            // instead of getting buried by a no-op duplicate.
            last.createdAt = .now
            try? ctx.save()
            return
        }

        let entry = RecentPlace(label: displayLabel, lat: lat, lng: lng, kind: kind)
        ctx.insert(entry)

        // Prune anything past the cap. We pull all rows (cheap at
        // 50 max), drop the head, delete the rest. FetchDescriptor
        // doesn't expose an offset for `delete` so a manual cleanup
        // is the simplest path.
        var allDesc = FetchDescriptor<RecentPlace>(
            sortBy: [SortDescriptor(\RecentPlace.createdAt, order: .reverse)]
        )
        allDesc.fetchLimit = Self.recentPlacesCap + 16
        if let all = try? ctx.fetch(allDesc), all.count > Self.recentPlacesCap {
            for old in all.dropFirst(Self.recentPlacesCap) {
                ctx.delete(old)
            }
        }
        try? ctx.save()
    }

    /// Clear the entire recent-places log. Called from the popover's
    /// "Clear history" button.
    func clearRecentPlaces() {
        guard let ctx = modelContext else { return }
        if let all = try? ctx.fetch(FetchDescriptor<RecentPlace>()) {
            for entry in all { ctx.delete(entry) }
            try? ctx.save()
        }
    }

    /// Delete one row from the popover's swipe / X button.
    func deleteRecentPlace(_ entry: RecentPlace) {
        guard let ctx = modelContext else { return }
        ctx.delete(entry)
        try? ctx.save()
    }

    // MARK: - Bookmarks JSON import (Phase 5.5)

    /// Open an NSOpenPanel for a `.json` file, parse it as a
    /// LocWarp-style bookmarks export, and bulk-insert each entry
    /// as a Bookmark record. Categories from the JSON become
    /// per-bookmark category strings — sidebar grouping happens
    /// for free via the existing `BookmarksSection` query path.
    ///
    /// Surface any error / "nothing imported" via `lastError` so the
    /// red toast in the map overlay tells the user what happened.
    @MainActor
    func importBookmarksJSON() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Import bookmarks from JSON",
            comment: "Title of the open-file dialog for bookmarks JSON import",
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try BookmarksJSONService.parse(url: url)
            guard !entries.isEmpty else {
                lastError = String(
                    localized: "JSON parsed, but no bookmarks were found.",
                    comment: "Toast when bookmark JSON import finds zero records",
                )
                return
            }
            for e in entries {
                addBookmark(name: e.name, lat: e.lat, lng: e.lng,
                            category: e.category)
            }
            lastError = String(
                format: String(
                    localized: "Imported %lld bookmarks.",
                    comment: "Toast after a successful bookmark JSON import",
                ),
                entries.count,
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Bookmarks JSON export + bulk paste (v1.9)

    /// Open an NSSavePanel and write all bookmarks out as LocWarp-style
    /// JSON. Filename defaults to `lociighost-bookmarks-YYYY-MM-DD.json`
    /// so successive exports don't overwrite each other unless the user
    /// picks the same name.
    @MainActor
    func exportBookmarksJSON() async {
        guard let ctx = modelContext else {
            lastError = String(localized: "Database not ready yet — try again in a second.")
            return
        }
        let all: [Bookmark]
        do {
            all = try ctx.fetch(FetchDescriptor<Bookmark>(
                sortBy: [SortDescriptor(\Bookmark.name)]
            ))
        } catch {
            lastError = "Couldn't read bookmarks: \(error.localizedDescription)"
            return
        }
        guard !all.isEmpty else {
            lastError = String(
                localized: "No bookmarks to export.",
                comment: "Toast when bookmark export is invoked on an empty list",
            )
            return
        }

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let defaultName = "lociighost-bookmarks-\(date.string(from: .now)).json"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.nameFieldStringValue = defaultName
        panel.title = String(
            localized: "Export bookmarks to JSON",
            comment: "Title of the save-file dialog for bookmarks JSON export",
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try BookmarksJSONService.encodeExport(bookmarks: all)
            try data.write(to: url, options: .atomic)
            lastError = String(
                format: String(
                    localized: "Exported %lld bookmarks.",
                    comment: "Toast after a successful bookmark JSON export",
                ),
                all.count,
            )
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Parse a multi-line paste blob and insert one bookmark per line.
    /// Returns the count actually inserted. Errors are surfaced via
    /// the returned count being zero + lastError; the caller should
    /// dismiss its paste sheet either way.
    /// Parse one coord per line (`lat, lng` — comma / tab / semicolon
    /// separators) and seed the multi-stop list with them so the user
    /// can build a long route by paste instead of clicking the map
    /// dozens of times. Reuses `BookmarksJSONService.parseBulkPaste`
    /// for the actual line parser since the format overlaps; we just
    /// discard the bookmark-only name / category fields.
    ///
    /// **Side-effect: teleports the iPhone to the first parsed coord
    /// BEFORE seeding the stops.** Without that, path-planning would
    /// route from wherever the iPhone currently is (often a different
    /// country entirely when the user is planning a trip abroad), and
    /// OSRM / MapKit either fail to plan an inter-continental polyline
    /// or render a useless straight line across the ocean. Teleporting
    /// to the first stop first makes path-planning a local problem.
    /// `teleport()` clears `pendingStops` as part of its single-action
    /// semantics, so we refill from `coords` after the teleport
    /// returns. The full parsed list (including the first coord) is
    /// staged so the user sees what they pasted; the first leg of
    /// the eventual Navigate is a zero-distance no-op.
    @MainActor
    @discardableResult
    func bulkAppendStops(from rawText: String) async -> Int {
        let entries = BookmarksJSONService.parseBulkPaste(rawText)
        guard !entries.isEmpty else {
            lastError = String(
                localized: "No valid coordinates found in the pasted text.",
                comment: "Toast when multi-stop bulk paste finds zero usable coords",
            )
            return 0
        }
        let coords = entries.map { Coordinate(lat: $0.lat, lng: $0.lng) }

        if let first = coords.first,
           let udid = selectedUDID,
           devices.first(where: { $0.udid == udid })?.connected == true {
            await teleport(udid: udid, lat: first.lat, lng: first.lng)
        }

        // Replace, not append: teleport just wiped pendingStops, and
        // the user's intent on a bulk paste is "this is my new route",
        // not "tack these onto whatever was staged before".
        pendingStops = coords

        lastError = String(
            format: String(
                localized: "Added %lld stops from paste.",
                comment: "Toast after a successful multi-stop bulk-paste insert",
            ),
            coords.count,
        )
        return coords.count
    }

    @MainActor
    @discardableResult
    func bulkAddBookmarks(from rawText: String, defaultCategory: String = "") -> Int {
        let entries = BookmarksJSONService.parseBulkPaste(rawText)
        guard !entries.isEmpty else {
            lastError = String(
                localized: "No valid bookmark lines found in the pasted text.",
                comment: "Toast when bookmark bulk paste finds zero usable lines",
            )
            return 0
        }
        for e in entries {
            let category = e.category.isEmpty
                ? defaultCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                : e.category
            addBookmark(name: e.name, lat: e.lat, lng: e.lng, category: category)
        }
        lastError = String(
            format: String(
                localized: "Added %lld bookmarks from paste.",
                comment: "Toast after a successful bookmark bulk-paste insert",
            ),
            entries.count,
        )
        return entries.count
    }

    // MARK: - Routes JSON import / export + force-restart (v1.9.1)

    /// Open an NSOpenPanel for a `.json` routes export, parse it, and
    /// bulk-insert each entry as a Route record. Mirrors
    /// `importBookmarksJSON()` for the routes table. Surfaces errors
    /// / "nothing imported" via `lastError`.
    /// Open NSOpenPanel for a JSON routes file, parse + bulk-insert. Returns
    /// a user-facing result string (success or failure) so callers presented
    /// in a sheet (Settings → Routes) can surface it inline — the
    /// MainView-mounted `lastError` toast is hidden behind the sheet.
    /// Returns `nil` only when the user cancels the open dialog.
    @MainActor
    func importRoutesJSON() async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Import routes from JSON",
            comment: "Title of the open-file dialog for routes JSON import",
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let entries = try RoutesJSONService.parse(url: url)
            guard !entries.isEmpty else {
                let msg = String(
                    localized: "JSON parsed, but no routes were found.",
                    comment: "Toast when route JSON import finds zero records",
                )
                lastError = msg
                return msg
            }
            for e in entries {
                saveImportedRoute(
                    name: e.name,
                    coordinates: e.points,
                    category: e.category,
                    iconSymbol: e.iconSymbol
                        ?? "point.bottomleft.forward.to.point.topright.scurvepath.fill",
                )
            }
            let msg = String(
                format: String(
                    localized: "Imported %lld routes.",
                    comment: "Toast after a successful route JSON import",
                ),
                entries.count,
            )
            lastError = msg
            return msg
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            return msg
        }
    }

    /// NSSavePanel → JSON for every saved Route. Default filename
    /// includes today's date so successive exports don't clobber.
    /// Returns a user-facing result string for sheet-local rendering
    /// (Settings → Routes); `nil` only when the user cancels the save
    /// dialog.
    @MainActor
    func exportRoutesJSON() async -> String? {
        guard let ctx = modelContext else {
            let msg = String(localized: "Database not ready yet — try again in a second.")
            lastError = msg
            return msg
        }
        let all: [Route]
        do {
            all = try ctx.fetch(FetchDescriptor<Route>(
                sortBy: [SortDescriptor(\Route.name)]
            ))
        } catch {
            let msg = "Couldn't read routes: \(error.localizedDescription)"
            lastError = msg
            return msg
        }
        guard !all.isEmpty else {
            let msg = String(
                localized: "No routes to export.",
                comment: "Toast when route export is invoked on an empty list",
            )
            lastError = msg
            return msg
        }

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let defaultName = "lociighost-routes-\(date.string(from: .now)).json"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.nameFieldStringValue = defaultName
        panel.title = String(
            localized: "Export routes to JSON",
            comment: "Title of the save-file dialog for routes JSON export",
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let data = try RoutesJSONService.encodeExport(routes: all)
            try data.write(to: url, options: .atomic)
            let msg = String(
                format: String(
                    localized: "Exported %lld routes.",
                    comment: "Toast after a successful route JSON export",
                ),
                all.count,
            )
            lastError = msg
            return msg
        } catch {
            let msg = "Export failed: \(error.localizedDescription)"
            lastError = msg
            return msg
        }
    }

    // MARK: - Full backup (v1.11.2)

    /// Dump every user-generated entity (bookmarks + routes + stop
    /// presets) to a single versioned JSON file via NSSavePanel.
    /// Designed for "I'm about to wipe / migrate / reinstall" — one
    /// file, one round-trip back through `importAllBackup()`.
    @MainActor
    func exportAllBackup() async {
        guard let ctx = modelContext else {
            lastError = String(localized: "Database not ready yet — try again in a second.")
            return
        }
        let bookmarks = (try? ctx.fetch(FetchDescriptor<Bookmark>(
            sortBy: [SortDescriptor(\Bookmark.createdAt)],
        ))) ?? []
        let routes = (try? ctx.fetch(FetchDescriptor<Route>(
            sortBy: [SortDescriptor(\Route.createdAt)],
        ))) ?? []
        let presets = (try? ctx.fetch(FetchDescriptor<StopPreset>(
            sortBy: [SortDescriptor(\StopPreset.createdAt)],
        ))) ?? []

        guard !bookmarks.isEmpty || !routes.isEmpty || !presets.isEmpty else {
            lastError = String(
                localized: "Nothing to back up — no bookmarks, routes, or stop presets yet.",
                comment: "Toast when full-backup export finds an empty database",
            )
            return
        }

        let bundle = FullBackupBundle(
            version: 1,
            exportedAt: .now,
            bookmarks: bookmarks.map {
                FullBackupBundle.BookmarkEntry(
                    name: $0.name,
                    lat: $0.lat,
                    lng: $0.lng,
                    category: $0.category,
                    iconSymbol: $0.iconSymbol,
                    createdAt: $0.createdAt,
                )
            },
            routes: routes.map {
                FullBackupBundle.RouteEntry(
                    name: $0.name,
                    category: $0.category,
                    iconSymbol: $0.iconSymbol,
                    points: $0.points.map { [$0.lat, $0.lng] },
                    createdAt: $0.createdAt,
                )
            },
            stopPresets: presets.map {
                FullBackupBundle.StopPresetEntry(
                    name: $0.name,
                    points: $0.coordinates.map { [$0.lat, $0.lng] },
                    createdAt: $0.createdAt,
                )
            },
        )

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let defaultName = "lociighost-backup-\(date.string(from: .now)).json"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.nameFieldStringValue = defaultName
        panel.title = String(
            localized: "Export all data (full backup)",
            comment: "Title of the save-file dialog for full backup export",
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(bundle)
            try data.write(to: url, options: .atomic)
            lastError = String(
                format: String(
                    localized: "Backed up %lld bookmarks · %lld routes · %lld presets.",
                    comment: "Toast after a successful full-backup export",
                ),
                bookmarks.count, routes.count, presets.count,
            )
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// Open a previously-exported backup JSON, prompt the user to pick
    /// a merge / overwrite strategy via NSAlert, then apply. Refuses to
    /// proceed if the version is newer than this build understands —
    /// downgrade-on-restore is a footgun we don't ship.
    @MainActor
    func importAllBackup() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Restore from backup JSON",
            comment: "Title of the open-file dialog for full backup import",
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle: FullBackupBundle
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            bundle = try decoder.decode(FullBackupBundle.self, from: data)
        } catch {
            lastError = "Restore failed: couldn't parse backup file — \(error.localizedDescription)"
            return
        }

        guard bundle.version <= 1 else {
            lastError = String(
                localized: "This backup is from a newer LociiGhost version. Please update before restoring.",
                comment: "Toast when full-backup import sees a higher schema version than this build supports",
            )
            return
        }

        // Strategy dialog — three buttons, NSAlert returns first /
        // second / third button for Merge / Overwrite / Cancel.
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Restore from backup?",
            comment: "Full-backup import — strategy dialog title",
        )
        alert.informativeText = String(
            format: String(
                localized: "This backup contains %lld bookmarks · %lld routes · %lld presets.\n\nMerge keeps your existing data and adds new entries (skipping name+coords duplicates).\nOverwrite wipes everything currently in LociiGhost and replaces it with the backup.",
                comment: "Full-backup import — strategy dialog body explaining merge vs overwrite",
            ),
            bundle.bookmarks.count, bundle.routes.count, bundle.stopPresets.count,
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "Merge",
            comment: "Full-backup import — merge button",
        ))
        alert.addButton(withTitle: String(
            localized: "Overwrite",
            comment: "Full-backup import — overwrite button (destructive)",
        ))
        alert.addButton(withTitle: String(
            localized: "Cancel",
            comment: "Full-backup import — cancel button",
        ))

        let response = alert.runModal()
        let strategy: BackupImportStrategy
        switch response {
        case .alertFirstButtonReturn:  strategy = .merge
        case .alertSecondButtonReturn: strategy = .overwrite
        default: return  // user cancelled
        }

        applyBackup(bundle, strategy: strategy)
    }

    /// Insert (and optionally wipe-first) bundle records into the
    /// SwiftData store. Dedupe key is `(name, coords)` for all three
    /// entity types — same name+different coords becomes a separate
    /// entry, same coords+different name becomes a separate entry.
    @MainActor
    private func applyBackup(_ bundle: FullBackupBundle, strategy: BackupImportStrategy) {
        guard let ctx = modelContext else {
            lastError = String(localized: "Database not ready yet — try again in a second.")
            return
        }

        if strategy == .overwrite {
            if let bms = try? ctx.fetch(FetchDescriptor<Bookmark>()) {
                for b in bms { ctx.delete(b) }
            }
            if let rs = try? ctx.fetch(FetchDescriptor<Route>()) {
                for r in rs { ctx.delete(r) }
            }
            if let ps = try? ctx.fetch(FetchDescriptor<StopPreset>()) {
                for p in ps { ctx.delete(p) }
            }
        }

        // Build dedupe sets up front so the per-entry merge check is
        // O(1); rebuilding the set per-entry would be O(N²) for a
        // big backup against a big database.
        var bookmarkKeys: Set<String> = []
        var routeKeys: Set<String> = []
        var presetKeys: Set<String> = []
        if strategy == .merge {
            if let bms = try? ctx.fetch(FetchDescriptor<Bookmark>()) {
                for b in bms {
                    bookmarkKeys.insert(Self.bookmarkKey(name: b.name, lat: b.lat, lng: b.lng))
                }
            }
            if let rs = try? ctx.fetch(FetchDescriptor<Route>()) {
                for r in rs {
                    routeKeys.insert(Self.coordsKey(name: r.name, points: r.points))
                }
            }
            if let ps = try? ctx.fetch(FetchDescriptor<StopPreset>()) {
                for p in ps {
                    presetKeys.insert(Self.coordsKey(name: p.name, points: p.coordinates))
                }
            }
        }

        var addedBookmarks = 0, addedRoutes = 0, addedPresets = 0

        for entry in bundle.bookmarks {
            if strategy == .merge,
               bookmarkKeys.contains(Self.bookmarkKey(name: entry.name, lat: entry.lat, lng: entry.lng)) {
                continue
            }
            let bm = Bookmark(
                name: entry.name,
                lat: entry.lat,
                lng: entry.lng,
                category: entry.category,
                iconSymbol: entry.iconSymbol,
                createdAt: entry.createdAt ?? .now,
            )
            ctx.insert(bm)
            addedBookmarks += 1
        }

        for entry in bundle.routes {
            let coords: [Coordinate] = entry.points.compactMap { pt in
                guard pt.count == 2 else { return nil }
                return Coordinate(lat: pt[0], lng: pt[1])
            }
            if strategy == .merge,
               routeKeys.contains(Self.coordsKey(name: entry.name, points: coords)) {
                continue
            }
            let r = Route(
                name: entry.name,
                points: coords,
                category: entry.category,
                iconSymbol: entry.iconSymbol,
                createdAt: entry.createdAt ?? .now,
            )
            ctx.insert(r)
            addedRoutes += 1
        }

        for entry in bundle.stopPresets {
            let coords: [Coordinate] = entry.points.compactMap { pt in
                guard pt.count == 2 else { return nil }
                return Coordinate(lat: pt[0], lng: pt[1])
            }
            if strategy == .merge,
               presetKeys.contains(Self.coordsKey(name: entry.name, points: coords)) {
                continue
            }
            let p = StopPreset(
                name: entry.name,
                coordinates: coords,
                createdAt: entry.createdAt ?? .now,
            )
            ctx.insert(p)
            addedPresets += 1
        }

        do {
            try ctx.save()
            lastError = String(
                format: String(
                    localized: "Restored: %lld bookmarks · %lld routes · %lld presets added.",
                    comment: "Toast after a successful full-backup restore",
                ),
                addedBookmarks, addedRoutes, addedPresets,
            )
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Dedupe key for Bookmark: name + 6-decimal coords. Six decimals
    /// is the same precision the UI prints, so two records that look
    /// identical to the user collapse to the same key.
    private static func bookmarkKey(name: String, lat: Double, lng: Double) -> String {
        "\(name)|\(String(format: "%.6f,%.6f", lat, lng))"
    }

    /// Dedupe key for Route / StopPreset: name + concatenated coords.
    /// Two routes with the same name but different points become
    /// distinct entries (the user clearly authored them separately).
    private static func coordsKey(name: String, points: [Coordinate]) -> String {
        let hash = points.map { String(format: "%.6f,%.6f", $0.lat, $0.lng) }
            .joined(separator: ";")
        return "\(name)|\(hash)"
    }

    /// Force-kill the running daemon and start a fresh one, requesting
    /// admin privileges through the standard macOS auth dialog. Used
    /// by the Settings sheet's "Force restart" button as a one-click
    /// recovery path so non-terminal users can recover from a stuck
    /// daemon without `kill` / `pkill` / `sudo` on the command line.
    ///
    /// Reuses `PrivilegedDaemonInstaller.install()` which already
    /// pkills any existing `-m lociighostd` process under both root
    /// and the user's uid before relaunching a clean daemon — exactly
    /// the same flow used during the very first launch, just with the
    /// app already up.
    @MainActor
    func forceRestartDaemon() async {
        // Disconnect locally before we ask the OS to kill the daemon
        // — the existing client's socket fd is about to become a
        // stale dangling reference. Setting `client = nil` flips the
        // UI to "Daemon disconnected" briefly, which is honest.
        if let existing = client {
            _ = try? await existing.callRaw("daemon.shutdown")
            await existing.disconnect()
        }
        client = nil
        // Use .starting — the existing DaemonStatus enum doesn't
        // carry a dedicated "restarting" case and the UI already
        // shows a sensible "Starting…" label for this state. No
        // need to widen the enum for a transient transition.
        daemonStatus = .starting

        do {
            try await PrivilegedDaemonInstaller.install()
            // PrivilegedDaemonInstaller.install() returns once the
            // socket exists; bootstrap() reconnects + re-hydrates
            // everything (device list, prefs, simulated location).
            // We re-set status to .stopped so bootstrap()'s guard
            // (`guard daemonStatus == .stopped`) lets it proceed.
            daemonStatus = .stopped
            await bootstrap()
            lastError = String(
                localized: "Daemon restarted successfully.",
                comment: "Toast after Force Restart finishes",
            )
        } catch PrivilegedDaemonInstaller.InstallError.userCancelled {
            // The user dismissed the auth dialog — reset status so
            // they can try again, and re-bootstrap to pick up any
            // pre-existing daemon that's still alive.
            daemonStatus = .stopped
            await bootstrap()
        } catch {
            daemonStatus = .stopped
            lastError = "Force restart failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Routes (Phase 5.4 — saved multi-point tracks)

    /// Persist a parsed GPX track as a new Route record. Routes are
    /// kept in their own SwiftData table so the sidebar's @Query
    /// re-renders independently of bookmarks. We trim the user-typed
    /// name and fall back to the GPX filename suggestion if they
    /// cleared it; an empty category is fine and lifts the route to
    /// the "Uncategorized" header in the sidebar.
    func saveImportedRoute(name: String,
                           coordinates: [Coordinate],
                           category: String = "",
                           iconSymbol: String = "point.bottomleft.forward.to.point.topright.scurvepath.fill") {
        guard let ctx = modelContext else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameToSave = trimmed.isEmpty
            ? String(localized: "Imported route",
                     comment: "Default Route name when the user cleared the import name field")
            : trimmed
        let r = Route(name: nameToSave,
                      points: coordinates,
                      category: category.trimmingCharacters(in: .whitespaces),
                      iconSymbol: iconSymbol)
        ctx.insert(r)
        try? ctx.save()
    }

    /// Update name / category / icon on an existing Route. We don't
    /// expose a way to edit the coordinates after import — re-import
    /// the GPX if the path itself is wrong.
    func updateRoute(_ route: Route,
                     name: String? = nil,
                     category: String? = nil,
                     iconSymbol: String? = nil) {
        guard let ctx = modelContext else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { route.name = trimmed }
        }
        if let category {
            route.category = category.trimmingCharacters(in: .whitespaces)
        }
        if let iconSymbol, !iconSymbol.isEmpty {
            route.iconSymbol = iconSymbol
        }
        try? ctx.save()
    }

    func deleteRoute(_ route: Route) {
        guard let ctx = modelContext else { return }
        ctx.delete(route)
        try? ctx.save()
    }

    /// v1.11.2: write a fresh waypoints list to an existing Route.
    /// The Route.points setter handles pointsJSON re-encoding and
    /// pointCount sync internally, so we just assign + save.
    func updateRouteWaypoints(_ route: Route, points: [Coordinate]) {
        guard let ctx = modelContext else { return }
        route.points = points
        try? ctx.save()
    }

    /// v1.11.2: run a coordinate list as a one-shot trip without
    /// touching any saved Route. Used by the "Run once (no save)"
    /// path in RouteWaypointsEditSheet — the user wants to try a
    /// tweak without committing it. Same teleport-then-navigate
    /// shape as `runRoute(_:udid:lapCount:)`, just no loopContext,
    /// no Route reference, no lapCount UI (single-trip only).
    @MainActor
    func runAdHocRoute(coords: [Coordinate], udid: String) async {
        guard !coords.isEmpty else {
            lastError = String(
                localized: "No waypoints to run.",
                comment: "Toast when Run once is invoked with an empty waypoint list",
            )
            return
        }
        let connected = devices.first(where: { $0.udid == udid })?.connected == true
        guard connected else {
            lastError = String(localized: "Connect a device first.")
            return
        }
        let speed = customSpeedMps ?? travelProfile.defaultSpeedMps
        let profile = travelProfile
        await teleport(udid: udid, lat: coords[0].lat, lng: coords[0].lng)
        if coords.count > 1 {
            let rest = Array(coords.dropFirst())
            await navigate(udid: udid, through: rest, profile: profile, speed: speed)
        }
    }

    /// Click-to-execute: teleport to the route's first point, then
    /// navigate through the rest as a straight-line multi-stop trip.
    ///
    /// Why straight-line? OSRM's HTTP API caps a request at ~8 KB of
    /// URL — a 200+ point track encoded as `lat,lng;lat,lng;…` busts
    /// that limit and the call fails. Straight-line skips OSRM
    /// entirely and walks the user's recorded path verbatim, which
    /// is what they actually want for a replayed GPX (deviating to
    /// the nearest road would defeat the point).
    ///
    /// We snapshot whatever the user had set for `useStraightLine`
    /// before the click so a subsequent ad-hoc multi-stop trip
    /// doesn't inherit straight-line mode they never asked for.
    @MainActor
    /// `lapCount`: how many times to walk the full route.
    /// * `1` (default) — single trip, no loop. Original behaviour.
    /// * `0` — loop forever; only `stopNavigation` ends it.
    /// * `>=2` — loop exactly `lapCount` times total.
    ///
    /// Loop semantics differ from the daemon's built-in `laps` param,
    /// which closes the route and *walks* the closure leg from end back
    /// to start. Users wanted instant teleport between laps (same as
    /// the initial "fly to route start" jump), so v1.10.7 moves the
    /// lap orchestration onto the Mac side: each lap runs as a fresh
    /// single-trip navigate, and a `loopContext` snapshot + the
    /// `applyStateEvent` "idle → idle" transition handler fires the
    /// next teleport-and-navigate when the previous lap completes
    /// naturally. User-Stop emits `stopped` (not `idle`), which clears
    /// `loopContext` and breaks the cycle cleanly.
    func runRoute(_ route: Route, udid: String, lapCount: Int = 1,
                  allowDwell: Bool = false, dwellSecondsForRoute: Int = 5) async {
        let coords = route.points
        guard !coords.isEmpty else {
            lastError = String(localized: "GPX file has no waypoints or track points.")
            return
        }
        let connected = devices.first(where: { $0.udid == udid })?.connected == true
        guard connected else {
            lastError = String(localized: "Connect a device first.")
            return
        }

        // v1.11.2 round 10 (T20 proper fix): if a previous route /
        // navigation is still running, explicitly stop it on the
        // daemon side before we kick off the new one. round 9's
        // app-side `clearActiveTrip` cleared the view state but
        // the daemon kept emitting position events for the old
        // route, so its waypoint pins kept getting re-attached to
        // the new device slot via `applyPositionEvent`'s
        // continuation. Sending a real `location.stop` first ensures
        // the daemon stops broadcasting before teleport+navigate
        // begins.
        if navigation != nil || randomWalk != nil {
            await stopNavigation(udid: udid)
            if randomWalk != nil {
                await stopRandomWalk(udid: udid)
            }
        }
        // After the stop, also explicitly wipe the staging list and
        // any cached preview polyline so the new route owns the
        // canvas cleanly — stopNavigation only clears the active
        // trip, not pendingStops.
        //
        // v1.11.2: also close any open movement-mode panel (most
        // importantly Multi-Stop). Without this, a user who starts a
        // route while the Multi-Stop sidebar is open can keep adding
        // stops during route playback, violating the single-active-
        // mode rule. Setting activeMovementMode → nil also triggers
        // its didSet which clears pendingStops when leaving .multiStop,
        // so the explicit clear below is belt-and-suspenders for other
        // modes (joystick, random walk) where the didSet does not clear.
        activeMovementMode = nil
        pendingStops = []
        schedulePreviewRefresh()

        let speed = customSpeedMps ?? travelProfile.defaultSpeedMps

        // Stash the loop plan for the event-handler-driven
        // continuation. `lapCount == 0` is the "until I press Stop"
        // sentinel and maps to Int.max here — every Stop press
        // clears `loopContext`, so leaving it ridiculously large is
        // safe.
        if lapCount == 0 {
            loopContext = LoopContext(
                routePoints: coords, udid: udid, profile: travelProfile, speed: speed,
                remainingLaps: Int.max,
                allowDwell: allowDwell,
                dwellSecondsForRoute: dwellSecondsForRoute,
            )
        } else if lapCount >= 2 {
            loopContext = LoopContext(
                routePoints: coords, udid: udid, profile: travelProfile, speed: speed,
                remainingLaps: lapCount - 1,
                allowDwell: allowDwell,
                dwellSecondsForRoute: dwellSecondsForRoute,
            )
        } else {
            loopContext = nil
        }

        // Each Mac-orchestrated lap runs as `daemon laps = 1`; the
        // existing per-AppState `routeLaps` (which the user may have
        // set for non-route trips) gets restored on return.
        let savedRouteLaps = routeLaps
        routeLaps = 1
        defer { routeLaps = savedRouteLaps }
        // Auto-teleport to the start so the navigate origin is the
        // recorded route's beginning regardless of where the user
        // last looked on the map.
        await teleport(udid: udid, lat: coords[0].lat, lng: coords[0].lng)
        // Pan + zoom the map to the start as well — teleport alone
        // moves the simulated puck but won't recenter, so a route
        // started from somewhere far off-screen would otherwise
        // require a manual map pan to even see what's happening.
        // 3 km span is wide enough to show the first few legs of a
        // typical walk/cycle without zooming out so far the puck
        // becomes a dot.
        pendingMapFly = MapFlyRequest(
            coordinate: coords[0],
            spanMeters: 3_000,
        )

        // Force straight-line for this call. Saved route = recorded
        // path; OSRM-snapping a 274-point trace would distort it
        // beyond recognition AND blow the URL-length budget.
        let savedStraightLine = useStraightLine
        useStraightLine = true
        defer { useStraightLine = savedStraightLine }

        // The first point is now the teleport origin; navigate
        // through everything AFTER it. If a one-point GPX somehow
        // landed here, the teleport above already did the right
        // thing — bail (and drop the loop context, since a one-point
        // "route" can't be replayed meaningfully).
        let stops = Array(coords.dropFirst())
        guard !stops.isEmpty else {
            loopContext = nil
            return
        }

        await navigate(udid: udid,
                       through: stops,
                       profile: travelProfile,
                       speed: speed,
                       allowDwell: allowDwell,
                       dwellOverride: allowDwell ? true : nil,
                       dwellSecondsOverride: allowDwell ? dwellSecondsForRoute : nil,
                       suppressDwellContext: true)
    }

    // MARK: - GPX import / export (Phase 5.4)

    /// Open an NSOpenPanel for a `.gpx` file, parse it, and surface
    /// the result through `pendingRouteImport` so the RouteEditSheet
    /// can ask the user for a name + category before persisting.
    ///
    /// We deliberately do NOT downsample or otherwise mutate the
    /// imported coordinates — a 274-point Tokyo walk should land in
    /// the saved route exactly as recorded. Click-to-execute on the
    /// resulting Route uses straight-line mode so OSRM's URL-length
    /// limit doesn't bite (see `runRoute`).
    @MainActor
    func importGPX() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gpx")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Import GPX",
                             comment: "Title of the open-file dialog for GPX import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let coords = try GPXService.loadCoordinates(from: url)
            // Prefill the name field with the filename stem. Most GPX
            // exports name the file after the trip ("morning-walk.gpx"
            // → "morning-walk"), and reusing that lets the user just
            // hit Save without retyping.
            let suggested = url.deletingPathExtension().lastPathComponent
            pendingRouteImport = PendingRouteImport(
                suggestedName: suggested,
                coordinates: coords,
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Save current `pendingStops` (the user's staged route) to a
    /// `.gpx` file via NSSavePanel. Refuses to save when the list
    /// is empty — File > Export menu item is disabled for that case
    /// already, this is a belt-and-suspenders guard.
    @MainActor
    func exportGPX() async {
        guard !pendingStops.isEmpty else {
            lastError = String(localized: "No stops staged yet.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gpx")!]
        panel.nameFieldStringValue = "lociighost-route.gpx"
        panel.title = String(localized: "Export current route as GPX…",
                             comment: "Title of the save-file dialog for GPX export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GPXService.write(coordinates: pendingStops, to: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard daemonStatus == .stopped else { return }
        daemonStatus = .starting

        // Land on the synthetic Map device on first launch so the
        // user has something selected (and the status bar's chips
        // have a context to react to) even before any iPhone is
        // discovered. If the user later picks an iPhone the
        // selection sticks; we only auto-pick Map when there's
        // nothing in `selectedUDID`.
        if selectedUDID == nil {
            selectedUDID = Self.virtualMapUDID
        }

        // Fire-and-forget update check. Runs in parallel with
        // daemon bring-up so it never blocks app launch. Failures
        // are silent — the header-bar badge just stays hidden.
        // (refreshPhoneSession used to live here too but it
        // requires the RPC client; moved below to after
        // `self.client` is established.)
        Task { await checkForUpdates() }

        // Stage the daemon out of `~/Documents` (TCC-protected on
        // macOS 15+) before we try to spawn it. This is a fast no-op
        // if the staged copy is already up to date.
        do {
            try await DaemonStaging.ensureStaged()
        } catch {
            let msg = "Daemon staging failed: \(error.localizedDescription)"
            lastError = msg
            daemonStatus = .failed(msg)
            return
        }

        // Fire off the Mac-location request in parallel with daemon bringup.
        // The fix typically lands within a second; if the user hasn't
        // granted permission yet they'll see the system prompt now.
        macLocation.requestPermissionAndFetch()

        let lifecycle = DaemonLifecycle()
        self.lifecycle = lifecycle
        do {
            try lifecycle.start()
            // Wait for the socket to appear (daemon binds it on startup).
            let path = LociiGhostPaths.socketPath
            let started = await Self.waitForSocket(path: path, timeout: 5.0)
            guard started else {
                daemonStatus = .failed("daemon socket did not appear")
                await triggerTahoeElevateAfterBootstrapFailure()
                return
            }

            let client = DaemonClient(socketPath: path)
            try await client.connect()
            self.client = client

            // Confirm liveness and learn the version.
            struct Pong: Decodable { let pong: Bool; let version: String }
            let pong: Pong = try await client.call("ping")
            daemonVersion = pong.version
            daemonStatus = .running

            // Now that the RPC client is up, seed the phone-
            // session + sync-mode state from the daemon. This
            // is what makes the Mac display the lockout
            // overlay when it (re)launches WHILE a phone tab
            // is already authenticated — without this, the
            // Mac stays at its default `phoneSessionActive=false`
            // because the daemon never re-broadcasts on
            // reconnect.
            Task { await refreshPhoneSession() }

            // ping just told us a live daemon version. If it matches
            // what this build expects, *unconditionally* clear the
            // "needs admin" sticky flag — we know the kill-and-restart
            // (or first-time spawn) succeeded and the daemon picked up
            // current bytecode. Without this, the banner can latch on
            // forever because the only previous clear point was tied to
            // a successful Connect, which the user can't reach until
            // the banner is gone in the first place.
            if pong.version == AppState.expectedDaemonVersion {
                needsAdminElevation = false
            }

            // Now that we have a live client, ask the daemon whether
            // it's running as root and matches the bundled-source
            // version. Either signal flips on the admin banner so the
            // user has a one-click path to fix it.
            await refreshDaemonPrivilegeAfterConnect()

            // v1.11.0: on macOS 26 Tahoe the system `usbmuxd` drops
            // non-root subscribers with "socket connection broken"
            // every few seconds — the daemon can subscribe but never
            // receives a device-attach event, so the user sees no
            // iPhone. The in-app AdminPromptBanner already offers
            // one-click elevation, but Tahoe users won't know the
            // banner is the answer — they'll think the app is broken.
            // Auto-fire the elevation flow once per app launch when
            // we land on Tahoe with an unprivileged daemon, so the
            // system auth dialog appears on its own at startup.
            await autoElevateOnTahoeIfNeeded()

            startEventLoop(client: client)

            await refreshDevices()
        } catch {
            daemonStatus = .failed(String(describing: error))
            await triggerTahoeElevateAfterBootstrapFailure()
        }
    }

    /// v1.11.2: When the bootstrap path fails on Tahoe — either the socket
    /// never came up (timed-out waitForSocket) or connect() threw
    /// ECONNREFUSED against a stale socket file — `daemonIsRoot` stays
    /// nil and `needsAdminElevation` stays false. `AdminPromptBanner`
    /// guards on `daemonIsRoot == false` which is unreachable from nil,
    /// and `autoElevateOnTahoeIfNeeded()` guards on the same. Result:
    /// red error chip in the status bar with no actionable banner and
    /// no system password prompt — a dead end for the user. Force the
    /// elevate flow so the system auth dialog appears once and the user
    /// can recover with one click. `attemptedTahoeAutoElevate` makes
    /// this fire at most once per app launch even if the user cancels.
    private func triggerTahoeElevateAfterBootstrapFailure() async {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        guard v.majorVersion >= 26 else { return }
        needsAdminElevation = true
        await autoElevateOnTahoeIfNeeded()
    }

    func teardown() async {
        eventTask?.cancel()
        eventTask = nil

        // Only shut the daemon down if WE spawned it. If we attached to an
        // already-running (typically sudo-launched) daemon, leave it alone
        // so the next app launch can re-attach without re-prompting for
        // the admin password — and so the in-memory device caches survive
        // an app close+reopen cycle (the on-disk cache is the safety net
        // for harder restarts where the daemon does die).
        let ownsDaemon = lifecycle?.attachedToExisting == false
        NSLog("LociiGhost.teardown: ownsDaemon=%@ (attachedToExisting=%@)",
              ownsDaemon ? "true" : "false",
              (lifecycle?.attachedToExisting ?? false) ? "true" : "false")
        if let client {
            if ownsDaemon {
                _ = try? await client.callRaw("daemon.shutdown")
            }
            await client.disconnect()
        }
        client = nil

        lifecycle?.stop()
        lifecycle = nil
        daemonStatus = .stopped
    }

    /// Terminate the app process. Same effect as Cmd-Q. Triggers the
    /// app delegate's `applicationWillTerminate` which calls `teardown()`.
    func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Devices

    func refreshDevices() async {
        guard let client else { return }
        do {
            let raw: AnyCodable = try await client.callRaw("device.list")
            let data = try JSONEncoder().encode(raw)
            let list = try JSONDecoder().decode([DeviceVM].self, from: data)
            self.devices = list

            // NOTE (v1.6): we used to nuke the simulated-location
            // record when the owning iPhone went offline. That
            // was too aggressive — the spoof on the iPhone is
            // still active (we never called restore), and when
            // the user reconnects within the same session we'd
            // already forgotten where they were. Now the
            // per-device dictionary keeps each device's slot
            // until either (a) `restore` clears it, (b) the
            // entry gets overwritten by a fresh teleport/event,
            // or (c) the app quits.

            // Auto-select the first connected device, or the only device.
            if selectedUDID == nil {
                selectedUDID = list.first(where: { $0.connected })?.udid
                    ?? list.first?.udid
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func connect(udid: String, preferWiFi: Bool = false) async {
        guard let client else { return }
        do {
            var params: [String: AnyCodable] = ["udid": AnyCodable(udid)]
            if preferWiFi {
                params["prefer_wifi"] = AnyCodable(true)
            }
            _ = try await client.callRaw("device.connect", params: params)
            await refreshDevices()
            // Kick a Mac CoreLocation fix now that a device session is
            // live — Restore-Real-GPS reads this proxy to fly the map
            // back to the user's actual location, and a stale startup-
            // time fix (or none at all, if permission was deferred) is
            // what kept Restore visually no-op'ing on disposable
            // installs. Re-asks for permission if the user denied
            // before; harmless if already granted.
            macLocation.requestPermissionAndFetch()
            // Successful Connect → tunnel built → daemon clearly has
            // enough privilege. Drop both "needs admin" signals so the
            // banner cannot reappear from a stale daemon.info that
            // never got a chance to update daemonIsRoot. (Earlier
            // versions cleared only `needsAdminElevation`, which left
            // daemonIsRoot==Optional(false) sticky from the original
            // user-mode bootstrap and made the banner re-show forever.)
            needsAdminElevation = false
            daemonIsRoot = true
        } catch {
            lastError = String(describing: error)
            // -32004 == TUNNEL_FAILED. On Apple Silicon the only thing
            // that fails this on USB is "daemon isn't root", because
            // utun creation in pytun_pmd3 needs CAP_NET_ADMIN-equivalent.
            if let rpc = error as? RPCError, rpc.code == -32004 {
                needsAdminElevation = true
            }
        }
    }

    func disconnect(udid: String) async {
        guard let client else { return }
        do {
            _ = try await client.callRaw("device.disconnect", params: ["udid": AnyCodable(udid)])
            // v1.6: don't nuke the per-device simulation record
            // on disconnect — the iPhone is still spoofed, and
            // switching back to the device should still show
            // its known location. Only clear live nav/joystick
            // state since those can't survive a disconnected
            // session anyway.
            if udid == selectedUDID {
                navigation = nil
                randomWalk = nil
                joystick = nil
            }
            await refreshDevices()
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - WiFi pairing + IP-direct connect

    /// Run the daemon's one-time `wifi.repair` ritual: USB autopair →
    /// CoreDeviceTunnelProxy → RSD → `create_core_device_tunnel_service_using_rsd(autopair=True)`
    /// which writes a fresh `~/.pymobiledevice3/remote_<UDID>.plist`.
    /// Two iOS Trust prompts appear during this; user must tap Trust on
    /// each. After this completes once, `connectWiFiByIP` works without
    /// the cable indefinitely.
    func pairForWiFi(udid: String? = nil) async {
        guard let client else { return }
        guard !isPairingForWiFi else { return }
        isPairingForWiFi = true
        defer { isPairingForWiFi = false }
        do {
            var params: [String: AnyCodable] = [:]
            if let udid { params["udid"] = AnyCodable(udid) }
            _ = try await client.callRaw("wifi.repair", params: params)
            lastError = nil
            // Pairing record is fresh — kick off discovery so the
            // newly-pairable iPhone appears in the WiFi list.
            await discoverWiFi()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Browse the LAN for paired iPhones (mDNS first, /24 TCP scan
    /// fallback). Stores results in `wifiCandidates` for the UI.
    func discoverWiFi() async {
        guard let client else { return }
        guard !isDiscoveringWiFi else { return }
        isDiscoveringWiFi = true
        defer { isDiscoveringWiFi = false }
        do {
            let raw: [WiFiCandidate] = try await client.call(
                "wifi.discover",
                params: ["scan_subnet": AnyCodable(true)]
            )
            wifiCandidates = raw
        } catch {
            wifiCandidates = []
            lastError = String(describing: error)
        }
    }

    /// Open the WiFi-connect selection sheet for `udid`. This is what
    /// the device row's "Connect via WiFi" button calls — instead of
    /// firing the legacy Bonjour-only connect path that returns a
    /// service-map-stripped RSD on iOS 26, the sheet auto-discovers
    /// LAN-reachable iPhones, lists them, and routes the user's pick
    /// through `connectWiFiByIP` (which opens the FULL RSD). If
    /// discovery returns nothing the sheet falls back to a manual
    /// IP entry field.
    func openWiFiConnectFlow(udid: String) {
        wifiConnectSheet = WiFiConnectSheetTarget(udid: udid)
        // Kick off a fresh discover so the sheet's list is current.
        // Fire-and-forget — the sheet's body re-renders as soon as
        // `wifiCandidates` updates.
        Task { await self.discoverWiFi() }
    }

    /// Connect to an iPhone discovered by `discoverWiFi()` (or any
    /// IP+port the user typed in manually). Uses the daemon's
    /// `wifi.connect_ip` which goes through
    /// `create_core_device_tunnel_service_using_remotepairing` directly,
    /// bypassing Bonjour at connect time and yielding the FULL RSD
    /// (with `dtservicehub`) — i.e. WiFi-only DVT location simulation
    /// works without a USB cable.
    ///
    /// On `-32004 TUNNEL_FAILED` (which on this path almost always
    /// means "iPhone moved to a different IP since the last
    /// discover"), kicks off a fresh `discoverWiFi()` automatically.
    /// The user sees the candidate list refresh and can click again
    /// without thinking about IP rotation.
    func connectWiFiByIP(ip: String, port: Int = 49152, udid: String? = nil) async {
        guard let client else { return }
        guard !isConnectingWiFiByIP else { return }
        isConnectingWiFiByIP = true
        defer { isConnectingWiFiByIP = false }
        do {
            var params: [String: AnyCodable] = [
                "ip": AnyCodable(ip),
                "port": AnyCodable(port),
            ]
            if let udid { params["udid"] = AnyCodable(udid) }
            _ = try await client.callRaw("wifi.connect_ip", params: params)
            lastError = nil
            await refreshDevices()
            // Same rationale as `connect()` — refresh the Mac
            // CoreLocation proxy now so Restore has a fresh fix.
            macLocation.requestPermissionAndFetch()
            // Successful Connect → full developer tunnel up → daemon is
            // exercising root utun, so admin signals are stale-clear.
            needsAdminElevation = false
            daemonIsRoot = true
        } catch {
            lastError = String(describing: error)
            if let rpc = error as? RPCError, rpc.code == -32004 {
                needsAdminElevation = true
            }
            // Tunnel failures on this path strongly correlate with the
            // iPhone having taken a new DHCP lease since we last
            // discovered. Fire-and-forget a refresh so the candidate
            // list is current next time the user clicks.
            Task { await self.discoverWiFi() }
        }
    }

    // MARK: - Phone control

    /// Candidate ports we walk when looking for the daemon's phone-
    /// control HTTP server. Must match `PORT_CANDIDATES` in
    /// `Daemon/lociighostd/http_server.py` — the daemon picks the
    /// first free one at startup, and this list is how we find
    /// where it actually landed without a separate RPC roundtrip.
    private static let phoneControlPorts: [Int] = [8779, 8780, 8781, 8788, 8789, 8800]

    /// Fetch the LAN URL + 6-digit PIN from the daemon's phone-control
    /// HTTP server. Walks the candidate-port list (the daemon may
    /// have fallen back from 8779 to 8780 etc. if a port was busy)
    /// and returns the first one that answers. The endpoint is
    /// localhost-only on the daemon, so we hit `127.0.0.1` directly
    /// over HTTP instead of going through our JSON-RPC socket.
    func fetchPhoneControlInfo() async {
        guard !isLoadingPhoneInfo else { return }
        isLoadingPhoneInfo = true
        defer { isLoadingPhoneInfo = false }
        for port in Self.phoneControlPorts {
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/phone/info")
            else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200
                else { continue }
                phoneControlInfo = try JSONDecoder().decode(PhoneControlInfo.self, from: data)
                return
            } catch {
                continue
            }
        }
        phoneControlInfo = nil
        lastError = "Phone control HTTP server isn't reachable on any candidate port (\(Self.phoneControlPorts.map(String.init).joined(separator: ", ")))."
    }

    /// Generate a fresh PIN + token. Invalidates any phone tab that
    /// was previously authed against the old token.
    func rotatePhoneControlPIN() async {
        // Use whichever port we already discovered — falls back to
        // re-walking the candidate list if we don't have one cached.
        let port: Int
        if let info = phoneControlInfo { port = info.port }
        else {
            await fetchPhoneControlInfo()
            guard let info = phoneControlInfo else { return }
            port = info.port
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/phone/rotate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            _ = try await URLSession.shared.data(for: req)
            await fetchPhoneControlInfo()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Open the phone-control sheet from anywhere in the UI. Auto-
    /// fetches info on appear so the sheet always shows current state.
    func openPhoneControlSheet() {
        showPhoneControlSheet = true
        Task { await fetchPhoneControlInfo() }
    }

    /// Ask the daemon to surface the Developer Mode toggle in iPhone Settings.
    /// Returns the next-step strings the daemon sent so the UI can show them.
    func revealDeveloperMode(udid: String) async -> [String] {
        guard let client else { return [] }
        struct Reply: Decodable { let ok: Bool; let next_steps: [String] }
        do {
            let reply: Reply = try await client.call("device.reveal_developer_mode",
                                                     params: ["udid": AnyCodable(udid)])
            return reply.next_steps
        } catch {
            lastError = String(describing: error)
            return []
        }
    }

    // MARK: - Gold Ditto (Pikmin Bloom 拉金盆 exploit, v1.4)

    /// Two-step burst: push iPhone GPS to A, then immediately
    /// clear so the iPhone reverts to real GPS. Used during a
    /// Pikmin Bloom gold-pot bud animation to fool the game into
    /// crediting the reward at the user's REAL location instead
    /// of the gold-pot's location — same gold pot can be milked
    /// repeatedly because the game records the "claim event" at
    /// A, not at the pot.
    ///
    /// Differs from a regular `teleport` + `restore`:
    ///
    ///   * Does NOT clear `pendingStops` / `navigation` /
    ///     `activeRoute` / `activeWaypoints` — the user might
    ///     have a route running and we don't want to disturb it
    ///   * Does NOT update `simulatedLocation` / fire the map fly
    ///     — desktop camera stays parked on the gold pot view
    ///   * Does NOT call any of the persistence hooks
    ///
    /// The whole point is "invisible round-trip from the desktop's
    /// perspective; only the phone's GPS actually moves."
    @MainActor
    func pullGoldDitto(udid: String, lat: Double, lng: Double) async {
        if udid == Self.virtualMapUDID {
            lastError = String(
                localized: "Gold Ditto needs a real iPhone connection.",
                comment: "Toast when the user fires Gold Ditto while the Map device is selected",
            )
            return
        }
        guard let client else { return }
        do {
            _ = try await client.callRaw("location.gold_ditto", params: [
                "udid": AnyCodable(udid),
                "lat":  AnyCodable(lat),
                "lng":  AnyCodable(lng),
            ])
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Teleport

    func teleport(udid: String, lat: Double, lng: Double) async {
        // Browse-only Map device — no daemon session, no RPC. The
        // map-click handler already updates `simulatedLocation`
        // for the chip refresh path; teleport here would just
        // fail with "no_origin" or similar.
        if udid == Self.virtualMapUDID { return }
        guard let client else { return }
        do {
            _ = try await client.callRaw("location.teleport", params: [
                "udid": AnyCodable(udid),
                "lat":  AnyCodable(lat),
                "lng":  AnyCodable(lng),
            ])
            lastTeleportedAt = Date()
            setSimulatedLocation(Coordinate(lat: lat, lng: lng), for: udid)
            // Force the geo + weather refresh in addition to the
            // simulatedLocation didSet hook — same belt-and-
            // suspenders rationale as `attachModelContext`.
            scheduleWeatherAndTzRefresh()
            pendingStops = []
            navigation = nil
            // Teleport replaces the trip for THIS device — wipe
            // its route/waypoint slot. Other devices' tripsByDevice
            // entries are untouched.
            clearActiveTrip(for: udid)
            // Recent-places log: blank label, the helper formats the
            // coord. Search-bar / bookmark callers pass an explicit
            // label via recordRecentPlace directly afterwards to
            // overwrite this default with a friendlier one.
            recordRecentPlace(label: "", lat: lat, lng: lng, kind: .teleport)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Move the simulated position to (lat, lng) via the daemon's
    /// location.teleport RPC — WITHOUT the UI side-effects of the
    /// public `teleport()` (no pendingStops clear, no navigation nil,
    /// no activeTrip wipe). Used exclusively for dwell lap-restarts
    /// where we only need the position updated for `navigationOrigin()`,
    /// and want the existing route/progress UI to survive intact.
    private func teleportPositionOnly(udid: String, lat: Double, lng: Double) async {
        guard let client else { return }
        do {
            _ = try await client.callRaw("location.teleport", params: [
                "udid": AnyCodable(udid),
                "lat":  AnyCodable(lat),
                "lng":  AnyCodable(lng),
            ])
            setSimulatedLocation(Coordinate(lat: lat, lng: lng), for: udid)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Plan a route from "current" through `stops` in order and start
    /// the iPhone moving along it at `speed`. With one stop this is a
    /// simple A→B navigation; with multiple it visits each stop in order
    /// before reaching the final destination.
    ///
    /// Origin is the current simulated location if we have one (chained
    /// navigation), else the Mac proxy fix.
    func navigate(udid: String, through stops: [Coordinate], profile: TravelProfile, speed: Double,
                  allowDwell: Bool = true, isLapContinuation: Bool = false,
                  /// When non-nil, overrides `self.dwellEnabled` for this call only.
                  /// Lets runRoute force-enable dwell without mutating global state.
                  dwellOverride: Bool? = nil,
                  /// When non-nil, overrides `self.dwellSeconds` for this call only.
                  dwellSecondsOverride: Int? = nil,
                  /// When true, set up DwellMonitor (in-route pause) but skip DwellContext
                  /// (end-of-route lap management). Used for saved-route playback where
                  /// loopContext already handles lap repetition.
                  suppressDwellContext: Bool = false) async {
        if udid == Self.virtualMapUDID { return }
        guard let client else { return }
        guard let origin = navigationOrigin() else {
            lastError = "Need a starting location: enable Mac location or teleport first."
            return
        }
        guard !stops.isEmpty else { return }

        // Always navigate the full stop list so the route polyline is
        // identical to a non-dwell trip. Dwell pauses are driven by
        // DwellMonitor (proximity → pause/resume) at intermediate stops
        // and by the idle event at the final stop.
        let effectiveStops = stops
        let waypoints = [origin] + effectiveStops
        // AnyCodable's encoder only walks the recursive shapes it knows
        // about: [AnyCodable] and [String: AnyCodable]. A bare
        // [[String: AnyCodable]] falls into its `default` branch and
        // throws "Unsupported AnyCodable value". Wrap each dict in
        // AnyCodable so the outer array becomes [AnyCodable].
        let stopsParam: [AnyCodable] = waypoints.map { c in
            AnyCodable([
                "lat": AnyCodable(c.lat),
                "lng": AnyCodable(c.lng),
            ])
        }

        do {
            struct Reply: Decodable {
                struct Route: Decodable {
                    let coordinates: [Coord]
                    let distance_m: Double
                    let duration_s: Double
                    let profile: String
                }
                struct Coord: Decodable { let lat: Double; let lng: Double }
                let route: Route
                let speed_mps: Double
            }
            // v1.9.1: engine + (optional) api_key go through with every
            // request. The daemon ignores them unless they tell it
            // something different than its current default, so older
            // clients keep working.
            let engine = routingEngine
            let effectiveStraightLine = useStraightLine || engine == .straightLine

            // v1.10: when the user picks MapKit, resolve the polyline here on
            // the Mac (MKDirections isn't reachable from the Python daemon)
            // and ship the pre-resolved coords as `polyline`. The daemon
            // detects `polyline` and skips its own engine dispatch — it just
            // plays the supplied coords. Other engines (OSRM, Google, straight
            // line) still route inside the daemon via `stops` like before.
            var polylineParam: [AnyCodable]? = nil
            if engine == .mapKit && !effectiveStraightLine {
                do {
                    let resolved = try await MapKitRouter.resolve(
                        waypoints: waypoints,
                        profile: profile.rawValue,
                    )
                    polylineParam = resolved.coordinates.map { c in
                        AnyCodable([
                            "lat": AnyCodable(c.lat),
                            "lng": AnyCodable(c.lng),
                        ])
                    }
                } catch {
                    // Apple Maps routing data is region-dependent — rural
                    // / mountainous areas (e.g. trails through Japan's
                    // Yamanashi prefecture) often have no driving or
                    // walking polylines available, and MKDirections
                    // returns "no route". OSRM's OSM-backed data covers
                    // these areas much better, so steer the user there
                    // rather than leaving them with just a generic
                    // failure message. The original error description
                    // is appended so debugging stays possible.
                    lastError = String(
                        format: String(localized: "Apple Maps couldn't plan this route — its data may not cover this area. Try switching the routing engine to OSRM in Settings. (%@)",
                                       comment: "Toast when MKDirections fails — suggests OSRM as the fallback engine"),
                        error.localizedDescription)
                    return
                }
            }

            var navParams: [String: AnyCodable] = [
                "udid":           AnyCodable(udid),
                "stops":          AnyCodable(stopsParam),
                "profile":        AnyCodable(profile.rawValue),
                "speed_mps":      AnyCodable(speed),
                "straight_line":  AnyCodable(effectiveStraightLine),
                // allowDwell=true → dwell or multi-stop, App controls laps,
                // always send laps=1 to daemon. allowDwell=false (route
                // playback) → daemon controls laps.
                "laps":           AnyCodable(allowDwell ? 1 : max(1, routeLaps)),
                "engine":         AnyCodable(engine.rawValue),
            ]
            if let polylineParam {
                navParams["polyline"] = AnyCodable(polylineParam)
            }
            if engine == .google, let key = googleGeocodeAPIKey {
                navParams["engine_api_key"] = AnyCodable(key)
            }
            let reply: Reply = try await client.call("location.navigate", params: navParams)
            let coords = reply.route.coordinates.map { Coordinate(lat: $0.lat, lng: $0.lng) }
            let displayedDistanceM = reply.route.distance_m
            let displayedEtaSeconds = reply.route.duration_s
            navigation = NavigationVM(
                state: .moving,
                profile: profile,
                speedMps: reply.speed_mps,
                routeCoordinates: coords,
                distanceM: displayedDistanceM,
                etaSeconds: displayedEtaSeconds,
                currentLocation: origin,
                progress: 0,
                // In dwell mode the daemon only runs 1 lap; the App
                // controls lap repetition via the idle handler. Setting
                // laps>1 would make currentLap jump based on progress
                // within the single daemon lap, causing the ETA chip to
                // display the wrong lap number.
                laps: allowDwell ? 1 : max(1, routeLaps)
            )
            setActiveTrip(
                route: coords,
                destination: effectiveStops.last ?? coords.last,
                isStraightLine: useStraightLine,
                waypoints: allowDwell ? pendingStops : stops,
                for: udid,
            )
            setSimulatedLocation(origin, for: udid)
            // Resolve effective dwell settings: callers (e.g. runRoute) can
            // pass explicit overrides so the global toggle / seconds don't
            // bleed into saved-route playback.
            let effectiveDwellEnabled = dwellOverride ?? dwellEnabled
            let effectiveDwellSeconds = dwellSecondsOverride ?? dwellSeconds
            if allowDwell, effectiveDwellEnabled, stops.count > 1 {
                // Route-snapped trigger coords: for each intermediate stop,
                // find the nearest point in the daemon's actual route
                // polyline (coords). The simulated position follows that
                // exact polyline, so it passes within a few metres of the
                // snapped point — far more reliable than the user's raw
                // dropped coordinate which may be 20–80 m off-road.
                // Last stop is excluded — it is handled by the idle event.
                let triggerCoords: [Coordinate] = stops.dropLast().map { stop in
                    coords.min(by: {
                        StopOrdering.haversineMeters($0, stop) < StopOrdering.haversineMeters($1, stop)
                    }) ?? stop
                }
                dwellLog("[DwellMonitor] setup: coordsCount=\(coords.count) stopsCount=\(stops.count) intermediateCount=\(triggerCoords.count) dwellSeconds=\(effectiveDwellSeconds)")
                for (i, tc) in triggerCoords.enumerated() {
                    let snapDist = StopOrdering.haversineMeters(tc, stops[i])
                    dwellLog("[DwellMonitor]   stop[\(i)] raw=(\(String(format:"%.5f",stops[i].lat)),\(String(format:"%.5f",stops[i].lng))) snap=(\(String(format:"%.5f",tc.lat)),\(String(format:"%.5f",tc.lng))) snapDist=\(String(format:"%.1f",snapDist))m")
                }
                dwellMonitor = DwellMonitor(
                    udid: udid,
                    stops: triggerCoords,
                    dwellSeconds: max(1, effectiveDwellSeconds),
                    thresholdM: 30.0
                )
                // suppressDwellContext == true: saved-route playback. loopContext
                // manages lap repetition (including end-of-lap dwell in the loop
                // handler). No DwellContext needed — it would conflict with loopContext
                // on the natural-idle event.
                if !suppressDwellContext {
                    // For lap continuations isLapContinuation=true; dwellContext
                    // is already set with the decremented lap count. Preserve it.
                    // For initial presses, start fresh from routeLaps.
                    if isLapContinuation, let prior = dwellContext {
                        // Lap continuation: stops is allStops.dropFirst() (origin=stop1).
                        // Preserve the full original stop list in allStops so the next
                        // lap restart can teleport to stop1 and route through all stops again.
                        dwellContext = DwellContext(
                            udid: udid,
                            profile: profile,
                            speed: speed,
                            dwellSeconds: max(1, effectiveDwellSeconds),
                            useStraightLine: useStraightLine,
                            allStops: prior.allStops,  // full list, not the dropFirst() stops
                            totalLaps: prior.totalLaps,
                            currentLap: prior.currentLap,
                            remainingDwellLaps: prior.remainingDwellLaps
                        )
                    } else {
                        dwellContext = DwellContext(
                            udid: udid,
                            profile: profile,
                            speed: speed,
                            dwellSeconds: max(1, effectiveDwellSeconds),
                            useStraightLine: useStraightLine,
                            allStops: stops,
                            totalLaps: max(1, routeLaps),
                            currentLap: 1,
                            remainingDwellLaps: max(0, routeLaps - 1)
                        )
                    }
                    // Patch NavigationVM with dwell-mode lap info so the BottomBar
                    // can show the correct "Lap N / M" counter. Must happen after
                    // dwellContext is set (initial) or updated (continuation).
                    if let dctx = dwellContext, var nav = navigation {
                        nav.dwellCurrentLap = dctx.currentLap
                        nav.dwellTotalLaps = dctx.totalLaps
                        navigation = nav
                    }
                }
            } else {
                dwellMonitor = nil
                if !allowDwell { dwellContext = nil }
            }
            multiStopLapContext = nil
            // v1.11.0: do NOT clear `pendingStops` after Navigate. Earlier
            // versions wiped the staging list as soon as the trip started,
            // which removed the on-panel coordinate list users wanted to
            // keep referring to. Per the new spec, the staged stops stay
            // visible (and continue to map-render as red pins on top of
            // the blue activeWaypoints) until the user explicitly clicks
            // Clear, or switches `activeMovementMode` away from
            // .multiStop — both handled elsewhere.
            // Log the destination — for multi-stop the user usually
            // cares most about "where am I heading", so we record the
            // final stop, not every intermediate waypoint.
            if let dest = stops.last {
                recordRecentPlace(label: "", lat: dest.lat, lng: dest.lng, kind: .navigate)
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func pauseNavigation(udid: String) async {
        guard let client else { return }
        _ = try? await client.callRaw("location.pause", params: ["udid": AnyCodable(udid)])
        if var nav = navigation {
            nav.state = .paused
            nav.pausedAt = Date()
            navigation = nav
        }
    }

    func resumeNavigation(udid: String) async {
        guard let client else { return }
        _ = try? await client.callRaw("location.resume", params: ["udid": AnyCodable(udid)])
        if var nav = navigation {
            nav.state = .moving
            nav.pausedAt = nil
            navigation = nav
        }
    }

    func stopNavigation(udid: String) async {
        guard let client else { return }
        // Explicit Stop cancels any auto-loop OR dwell-mode sequence
        // in flight. Clearing before the RPC means an
        // `applyStateEvent` arriving mid-stop already sees the empty
        // context and won't fire a fresh lap or fresh dwell leg.
        if loopContext?.udid == udid { loopContext = nil }
        if dwellContext?.udid == udid { dwellContext = nil }
        if dwellMonitor?.udid == udid { dwellMonitor = nil }
        if multiStopLapContext?.udid == udid { multiStopLapContext = nil }
        _ = try? await client.callRaw("location.stop", params: ["udid": AnyCodable(udid)])
        navigation = nil
        // Stop cancels THIS device's trip — wipe just its slot
        // in the per-device tripsByDevice dict. Other iPhones
        // running their own trips stay drawn.
        clearActiveTrip(for: udid)
    }

    /// Clear all simulation state and staged stops without snapping
    /// the iPhone back to real GPS. The iPhone stays at its last
    /// simulated position. Used by the BottomBar "Clear" button.
    func clearAllState(udid: String) async {
        if navigationActive { await stopNavigation(udid: udid) }
        if randomWalkActive  { await stopRandomWalk(udid: udid) }
        if joystickActive    { await stopJoystick(udid: udid) }
        pendingStops = []
        activeMovementMode = nil
        schedulePreviewRefresh()
    }

    // ------------------------------------------------------------------
    // Random walk
    // ------------------------------------------------------------------

    /// Start a random-walk simulation centred on `center`, drifting up to
    /// `radiusM` metres away at speeds within the given band (m/s).
    func startRandomWalk(udid: String,
                         center: Coordinate,
                         radiusM: Double,
                         minSpeedMps: Double,
                         maxSpeedMps: Double,
                         routingEngine: String = "straight") async {
        if udid == Self.virtualMapUDID { return }
        guard let client else { return }
        do {
            struct StartReply: Decodable {
                struct Coord: Decodable { let lat: Double; let lng: Double }
                let planned_path: [Coord]?
            }
            // v1.11.0: pass dwell_seconds when the user has enabled
            // per-stop dwell — same setting as multi-stop, so a single
            // flip in either panel affects both modes.
            var params: [String: AnyCodable] = [
                "udid":           AnyCodable(udid),
                "center_lat":     AnyCodable(center.lat),
                "center_lng":     AnyCodable(center.lng),
                "radius_m":       AnyCodable(radiusM),
                "min_speed_mps":  AnyCodable(minSpeedMps),
                "max_speed_mps":  AnyCodable(maxSpeedMps),
                "routing_engine": AnyCodable(routingEngine),
            ]
            if dwellEnabled {
                params["dwell_seconds"] = AnyCodable(Double(max(1, dwellSeconds)))
            }
            let reply: StartReply = try await client.call("location.random_walk", params: params)
            randomWalk = RandomWalkVM(
                center: center,
                radiusM: radiusM,
                current: center,
                speedMps: 0,
                distanceTraveledM: 0,
                isMoving: true,
                plannedPath: (reply.planned_path ?? []).map {
                    Coordinate(lat: $0.lat, lng: $0.lng)
                }
            )
            // Drop other movement modes from the local view so the UI
            // doesn't render stale state from a previous mode.
            navigation = nil
            joystick = nil
            setSimulatedLocation(center, for: udid)
        } catch {
            lastError = String(describing: error)
        }
    }

    func stopRandomWalk(udid: String) async {
        guard let client else { return }
        _ = try? await client.callRaw("location.stop", params: ["udid": AnyCodable(udid)])
        randomWalk = nil
    }

    // ------------------------------------------------------------------
    // Joystick
    // ------------------------------------------------------------------

    /// Begin a joystick session. Origin defaults to the current simulated
    /// (or Mac proxy) location so the first frame the iPhone sees is
    /// "where it already thinks it is", not a sudden teleport.
    func startJoystick(udid: String, origin: Coordinate) async {
        if udid == Self.virtualMapUDID { return }
        guard let client else { return }
        do {
            _ = try await client.callRaw("location.joystick.start", params: [
                "udid": AnyCodable(udid),
                "lat":  AnyCodable(origin.lat),
                "lng":  AnyCodable(origin.lng),
            ])
            joystick = JoystickVM(
                current: origin,
                headingDeg: 0,
                speedMps: 0,
                isMoving: false
            )
            navigation = nil
            randomWalk = nil
            setSimulatedLocation(origin, for: udid)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Push a (heading, speed) update into the active joystick session.
    /// `speedMps == 0` parks the controller — iPhone freezes in place
    /// until the next non-zero update.
    func updateJoystick(udid: String, headingDeg: Double, speedMps: Double) async {
        guard let client else { return }
        _ = try? await client.callRaw("location.joystick.update", params: [
            "udid":        AnyCodable(udid),
            "heading_deg": AnyCodable(headingDeg),
            "speed_mps":   AnyCodable(speedMps),
        ])
        if var js = joystick {
            js.headingDeg = headingDeg
            js.speedMps = speedMps
            js.isMoving = speedMps > 0
            joystick = js
        }
    }

    func stopJoystick(udid: String) async {
        guard let client else { return }
        _ = try? await client.callRaw("location.stop", params: ["udid": AnyCodable(udid)])
        joystick = nil
    }

    func applyNavigationSpeed(udid: String, speedMps: Double) async {
        guard let client else { return }
        _ = try? await client.callRaw("location.apply_speed", params: [
            "udid": AnyCodable(udid),
            "speed_mps": AnyCodable(speedMps),
        ])
        if var nav = navigation {
            nav.speedMps = speedMps
            // Client-side ETA recalc so the BottomBar reflects the new
            // speed immediately without waiting for the next daemon
            // position event. The daemon will refine this on its next
            // tick; this just removes the ~1 s stale-ETA glitch.
            if speedMps > 0 {
                let remaining = nav.distanceM * max(0, 1 - nav.progress)
                nav.etaSeconds = remaining / speedMps
                nav.etaRefAt = Date()
            }
            navigation = nav
        }
    }

    /// Switch travel mode mid-route. The route polyline doesn't change
    /// (it was computed for the original profile), only the speed at
    /// which we walk it. This is the hot-swap from the original LociiGhost.
    func changeNavigationProfile(udid: String, to profile: TravelProfile) async {
        let speed = customSpeedMps ?? profile.defaultSpeedMps
        await applyNavigationSpeed(udid: udid, speedMps: speed)
        if var nav = navigation {
            nav.profile = profile
            navigation = nav
        }
        // Keep the global picker in sync so the next Navigate uses the
        // mode the user just picked.
        travelProfile = profile
    }

    // ------------------------------------------------------------------
    // Admin elevation
    // ------------------------------------------------------------------

    /// Show the macOS admin auth prompt, then bring up a privileged
    /// daemon and reconnect. The user never has to open a terminal —
    /// this is the same dialog Installer.app uses.
    ///
    /// On cancellation we leave the existing (likely unprivileged)
    /// daemon alone so the user can keep using the app's read-only
    /// features (device discovery, Mac-location proxy, etc.).
    func requestAdminElevation() async {
        guard !isElevating else { return }
        isElevating = true
        defer { isElevating = false }

        // Reset privilege state to "unknown" *now*, before we tear
        // anything down. Without this, a stale `daemonIsRoot ==
        // Optional(false)` from the original user-mode bootstrap
        // remains sticky if the post-install daemon.info call fails
        // for any reason (race against daemon startup, transient
        // socket reset, etc.), and the banner stays up forever.
        // nil != false, so the banner is dismissed while we're
        // re-elevating; refreshDaemonPrivilegeAfterConnect will set
        // it to a definite Bool once the new daemon answers.
        daemonIsRoot = nil

        // Tear our current connection down first so we don't try to
        // talk to a daemon that's about to be killed by the bootstrap
        // script.
        eventTask?.cancel()
        eventTask = nil
        if let c = client {
            await c.disconnect()
        }
        client = nil
        // The lifecycle reference belongs to whichever daemon we
        // spawned (or attached to) earlier — drop it without sending
        // shutdown so we don't accidentally restart the kill loop.
        lifecycle?.stop()
        lifecycle = nil
        daemonStatus = .stopped

        // Re-stage the daemon before privilege install so the root
        // daemon picks up any source changes since last launch. Day-
        // to-day fixes (e.g. the QUIC→TCP tunnel switch) only take
        // effect once the daemon is restarted with the new files.
        do {
            try await DaemonStaging.ensureStaged()
        } catch {
            lastError = "Daemon staging failed: \(error.localizedDescription)"
        }

        do {
            try await PrivilegedDaemonInstaller.install()
            needsAdminElevation = false
            lastError = nil
            // Re-bootstrap will see the now-existing privileged socket
            // and attach to it.
            await bootstrap()
            await refreshDevices()
        } catch PrivilegedDaemonInstaller.InstallError.userCancelled {
            // User chose not to authenticate. Restore the basic
            // unprivileged daemon so the app isn't dead in the water.
            await bootstrap()
        } catch {
            lastError = "Admin install failed: \(error.localizedDescription)"
            await bootstrap()
        }
    }

    /// True once we've already fired (or attempted) the Tahoe auto-
    /// elevation flow this app launch. Prevents the system auth
    /// dialog from re-triggering after every reconnect — once the
    /// user has answered (yes or cancel) we leave them alone for the
    /// rest of the session.
    private var attemptedTahoeAutoElevate: Bool = false

    /// On macOS 26 Tahoe, the system `usbmuxd` only delivers
    /// device-attach events reliably to root subscribers; user-mode
    /// daemons get their subscription torn down repeatedly with
    /// "socket connection broken". The in-app AdminPromptBanner
    /// offers one-click elevation, but new users may not understand
    /// the banner is the fix — they expect a system prompt at first
    /// launch. This helper fires `requestAdminElevation()` once per
    /// session in either of two situations:
    ///
    /// 1. We land on Tahoe with an unprivileged daemon (the original
    ///    Tahoe-only case).
    /// 2. The running daemon is stale (binary on disk is newer than
    ///    the running process). Without auto-elevation here, the user
    ///    has no way to know their dev-time daemon swap didn't take
    ///    effect — the in-process daemon keeps running the old code
    ///    silently.
    @MainActor
    private func autoElevateOnTahoeIfNeeded() async {
        guard !attemptedTahoeAutoElevate else { return }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let isTahoe = v.majorVersion >= 26
        let isUnprivilegedOnTahoe = isTahoe && (daemonIsRoot == false)
        let isStale = needsAdminElevation
        guard isUnprivilegedOnTahoe || isStale else { return }
        attemptedTahoeAutoElevate = true
        await requestAdminElevation()
    }

    /// Probe the connected daemon to see if it's running as root, so
    /// the UI knows whether to offer an "Authenticate as admin"
    /// affordance up front rather than waiting for a connect failure.
    /// Also checks the daemon's version: if it's older than the
    /// version bundled with this app build, the daemon process is
    /// running stale in-memory bytecode and we should ask the user
    /// to re-authenticate so the kill-and-restart picks up the new
    /// code.
    private func refreshDaemonPrivilegeAfterConnect() async {
        guard let client else { return }
        struct InfoReply: Decodable {
            let is_root: Bool?
            let version: String?
            let start_time: Double?
        }
        guard let reply: InfoReply = try? await client.call("daemon.info") else {
            return
        }
        daemonIsRoot = reply.is_root

        // v1.11.0: detect a daemon process whose binary has been
        // overwritten on disk while the old process is still running.
        // We can't bump `__version__` for every internal daemon change
        // (would surface in About as `1.11.0-r5`), but we CAN compare
        // process start time vs the bundled binary's mtime. If the on-
        // disk binary is newer than the process start, the running
        // daemon is stale and a kill + restart picks up the new code.
        //
        // A daemon that doesn't return `start_time` at all predates the
        // version that added the field, which by definition means a
        // newer daemon binary is sitting on disk waiting to replace it
        // — also treat as stale.
        var staleProcess = false
        if let bundleDaemonMtime = bundledDaemonBinaryMtime() {
            if let startTime = reply.start_time {
                if bundleDaemonMtime > startTime + 5.0 {
                    staleProcess = true
                }
            } else {
                // Legacy daemon — pre-start_time field. The daemon
                // bundled with this app build added start_time, so a
                // missing field means the running process is older.
                staleProcess = true
            }
        }

        if let liveVersion = reply.version,
           liveVersion != AppState.expectedDaemonVersion {
            // Daemon is alive but its bytecode predates this app
            // build's daemon source. Surface the auth banner; clicking
            // Authenticate will trigger the kill-and-restart flow.
            needsAdminElevation = true
        } else if staleProcess {
            // Same major version, but the binary on disk has been
            // updated since the daemon process started (typical case:
            // a dev cp-into-/Applications swap while the privileged
            // daemon kept running). Surface the banner so the user
            // can re-authenticate and pick up the new code.
            needsAdminElevation = true
        } else if reply.version == AppState.expectedDaemonVersion {
            // Versions match AND binary is up to date — the previous
            // "stale daemon" condition (if any) has been resolved by
            // the kill-and-restart flow. Without this clear,
            // `needsAdminElevation` stays sticky-true forever and the
            // banner reappears on every connect even though the daemon
            // is already up to date.
            needsAdminElevation = false
        }
    }

    /// Path to the daemon binary inside the LociiGhost.app bundle.
    /// `Bundle.main.resourceURL` resolves to `Contents/Resources/`
    /// which is where `package-app.sh` lays the daemon out at build
    /// time. Returns nil for unit-test / SwiftPM runs without an .app
    /// bundle wrapper (where the comparison doesn't apply anyway).
    private func bundledDaemonBinaryMtime() -> TimeInterval? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let daemonPath = resourceURL
            .appendingPathComponent("lociighostd")
            .appendingPathComponent("lociighostd")
            .path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: daemonPath),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return mtime.timeIntervalSince1970
    }

    /// Bumped every time the daemon source breaks ABI or behaviour in
    /// a way that requires an in-place restart. Must match the
    /// `__version__` in `Daemon/lociighostd/__init__.py`.
    static let expectedDaemonVersion = "1.11.1"

    // MARK: - Update check (v1.5)

    /// Latest version reported by the remote release manifest, or
    /// nil when (a) we haven't fetched yet, (b) the fetch failed,
    /// or (c) we ARE on the latest version. Treat non-nil as "we
    /// have a known-newer release the user should hear about".
    var latestVersion: String?
    /// Release page / changelog URL from the manifest. Clicked
    /// from the header-bar update badge; nil → badge stays
    /// non-clickable (just informational).
    var latestVersionURL: URL?

    /// One-shot fire-and-forget check. Called from `bootstrap()`;
    /// safe to call again later (e.g. from a manual "check now"
    /// button) — it just overwrites the two fields above.
    @MainActor
    func checkForUpdates() async {
        guard let manifest = await UpdateService.fetchLatest() else { return }
        if UpdateService.isNewer(
            remote: manifest.version,
            than: Self.expectedDaemonVersion,
        ) {
            latestVersion = manifest.version
            latestVersionURL = manifest.url
        } else {
            // User caught up — clear any stale badge state.
            latestVersion = nil
            latestVersionURL = nil
        }
    }

    // MARK: - Virtual Map device (browse-only mode)

    /// Sentinel UDID for the synthetic "Map" device. Always present
    /// in the sidebar so the user has somewhere to land when no
    /// iPhone is connected — picking it lets them browse the map
    /// and see Status-Bar A info (country, weather, time at the
    /// clicked location) without any RPC machinery in the loop.
    /// The string is intentionally weird so it can never collide
    /// with a real iPhone UDID (those are 25-char or 40-char hex).
    static let virtualMapUDID = "__virtual_map__"

    /// True when the user has the synthetic Map device selected.
    /// Lets call sites short-circuit teleport / navigate / movement
    /// mode RPCs that would otherwise try to talk to a non-existent
    /// daemon session.
    var isVirtualMapSelected: Bool {
        selectedUDID == Self.virtualMapUDID
    }

    /// The synthetic device row. Always-connected, no transport,
    /// dev-mode irrelevant. Sidebar's `DeviceRow` checks the udid
    /// against `virtualMapUDID` to render a map glyph instead of
    /// the iPhone glyph and to suppress Connect/Disconnect buttons.
    private var virtualMapDevice: DeviceVM {
        DeviceVM(
            udid: Self.virtualMapUDID,
            name: "Map",
            ios_version: "—",
            transport: "virtual",
            connected: true,
            developer_mode: nil,
            transports: [],
            wifi_paired: nil,
            peer_ip: nil,
            peer_port: nil,
        )
    }

    /// Sidebar-visible device list — real devices from the daemon
    /// PLUS the synthetic Map row at the top. Sort order:
    ///
    ///   1. Map (always pinned, always usable)
    ///   2. Connected iPhones (currently driveable)
    ///   3. Disconnected iPhones (paired but offline)
    ///
    /// Within each of (2) and (3), preserve the daemon's reported
    /// order — that's typically usbmuxd's discovery order, which
    /// is stable enough that rows don't shuffle around when the
    /// user is mid-interaction.
    var displayedDevices: [DeviceVM] {
        let connected = devices.filter(\.connected)
        let offline   = devices.filter { !$0.connected }
        return [virtualMapDevice] + connected + offline
    }

    /// True when the user has selected a real iPhone row that is
    /// not currently connected (i.e. picked it in the sidebar but
    /// the session is dead). Drives the grey-out + "已斷線"
    /// overlay on the map. The synthetic Map device is NEVER
    /// considered disconnected (it's always usable for browsing).
    var selectedDeviceIsDisconnected: Bool {
        guard let udid = selectedUDID else { return false }
        if udid == Self.virtualMapUDID { return false }
        guard let dev = devices.first(where: { $0.udid == udid }) else {
            return false
        }
        return !dev.connected
    }

    /// True when no device is selected at all (covers the first-
    /// launch case where the sidebar selection hasn't landed on
    /// the Map row yet either). Map should still be interactive
    /// in this state — the overlay only fires for "selected an
    /// iPhone, but it's disconnected".
    var hasNoSelectedDevice: Bool {
        selectedUDID == nil
    }

    /// Pick the right starting coordinate for a new navigation. Order:
    /// 1. Currently simulated location (chain another route on top).
    /// 2. Mac proxy location (≈ iPhone real GPS).
    private func navigationOrigin() -> Coordinate? {
        if let sim = simulatedLocation { return sim }
        if let mac = macLocation.coordinate {
            return Coordinate(lat: mac.latitude, lng: mac.longitude)
        }
        return nil
    }

    // ------------------------------------------------------------------
    // Route preview
    // ------------------------------------------------------------------

    /// Rebuild `previewRoute` to match the current pendingStops + mode.
    ///
    /// * Straight-line mode: instant local compute (origin + stops as
    ///   the polyline). No daemon call.
    /// * Road mode: debounced OSRM lookup via `routing.route`. The
    ///   debounce keeps us from hitting the public OSRM server on every
    ///   keystroke / click while the user is still placing pins.
    func schedulePreviewRefresh() {
        previewTask?.cancel()

        if pendingStops.isEmpty {
            previewRoute = []
            return
        }

        if useStraightLine {
            // Local compute — no network. Show immediately.
            previewIsStraightLine = true
            if let origin = navigationOrigin() {
                previewRoute = [origin] + pendingStops
            } else {
                previewRoute = pendingStops
            }
            return
        }

        // Road mode — defer to the daemon, debounced.
        let stopsSnapshot = pendingStops
        let originSnapshot = navigationOrigin()
        let profile = travelProfile
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await self?.fetchPreviewViaOSRM(stops: stopsSnapshot,
                                            origin: originSnapshot,
                                            profile: profile)
        }
    }

    private func fetchPreviewViaOSRM(stops: [Coordinate],
                                     origin: Coordinate?,
                                     profile: TravelProfile) async {
        guard let client else { return }
        let waypoints: [Coordinate] = origin.map { [$0] + stops } ?? stops
        guard waypoints.count >= 2 else {
            previewRoute = []
            return
        }
        let stopsParam: [AnyCodable] = waypoints.map { c in
            AnyCodable(["lat": AnyCodable(c.lat), "lng": AnyCodable(c.lng)])
        }

        struct Reply: Decodable {
            struct Coord: Decodable { let lat: Double; let lng: Double }
            let coordinates: [Coord]
        }
        do {
            let reply: Reply = try await client.call("routing.route", params: [
                "stops":   AnyCodable(stopsParam),
                "profile": AnyCodable(profile.rawValue),
            ])
            // Avoid stomping on a more recent preview if the user has
            // already changed the inputs while we were awaiting OSRM.
            guard pendingStops == stops, !useStraightLine else { return }
            previewRoute = reply.coordinates.map { Coordinate(lat: $0.lat, lng: $0.lng) }
            previewIsStraightLine = false
        } catch {
            // Don't surface OSRM failures here -- the preview is best-
            // effort and it's noisy to flash an error every keystroke.
            // The next Navigate click will surface anything important.
        }
    }

    func restore(udid: String) async {
        guard let client else { return }
        do {
            _ = try await client.callRaw("location.restore", params: ["udid": AnyCodable(udid)])
            setSimulatedLocation(nil, for: udid)
            navigation = nil
            // Real GPS resumed for THIS device — clear its trip
            // slot. Other devices' trips are unaffected.
            clearActiveTrip(for: udid)

            // Fly map back to the iPhone's real-GPS proxy. Apple doesn't
            // expose iPhone CoreLocation over DVT, so the Mac's own
            // CoreLocation is our single source of truth. Earlier
            // revisions flew to whatever `macLocation.coordinate`
            // happened to hold (often a stale startup-time fix or nil)
            // and called `refresh()` afterwards — by which time the
            // map had already settled on the wrong spot. Now we
            // explicitly *await* a fresh fix before flying.
            if let fresh = await macLocation.fetchFreshFix(timeout: 2.0) {
                pendingMapFly = MapFlyRequest(
                    coordinate: Coordinate(lat: fresh.latitude, lng: fresh.longitude),
                    spanMeters: 2_000
                )
            } else if let cached = macLocation.coordinate {
                // Permission OK but the fresh fix didn't land within
                // the timeout window. Flying to the most recent value
                // is still better than leaving the map frozen on the
                // now-stale simulated trail.
                pendingMapFly = MapFlyRequest(
                    coordinate: Coordinate(lat: cached.latitude, lng: cached.longitude),
                    spanMeters: 2_000
                )
            } else {
                // No fix at all — typically means location permission
                // isn't granted (or the radio is cold and the request
                // is still inflight). Tell the user explicitly instead
                // of silently leaving the map where it was.
                lastError = String(
                    localized: "Can't read Mac location. Open System Settings → Privacy & Security → Location Services and allow LociiGhost.",
                    comment: "Error toast after Restore when CoreLocation has no fix"
                )
            }

            // DVT clear() stops the fake feed instantly, but the iPhone
            // GPS chip still has to re-acquire a real fix — typically
            // 30 s outdoors, sometimes 1–2 min indoors. Tell the user
            // up front so they don't think Restore "didn't do anything".
            showInfo(String(
                localized: "Real GPS may take 30 s to 2 min to re-acquire on iPhone. Toggle Airplane Mode on the iPhone for faster reacquisition.",
                comment: "Info toast after Restore — explains GPS reacquisition delay"
            ))
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Event loop

    private func startEventLoop(client: DaemonClient) {
        eventTask = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                await self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: RPCEvent) async {
        switch event.method {
        case "event.device_changed":
            await refreshDevices()
        case "event.position_update":
            applyPositionEvent(event.params)
        case "event.state_changed":
            applyStateEvent(event.params)
        case "event.wifi_pair_progress":
            applyPairProgressEvent(event.params)
        case "event.phone_session":
            if let b = unwrapBool(event.params["active"]) {
                phoneSessionActive = b
            }
            // Daemon sends `udids: [...]` — the de-duped set
            // of iPhones currently being driven across all
            // phone sessions. `AnyCodable` decodes JSON arrays
            // as `[AnyCodable]` (each element wrapped), so the
            // cast must be `as? [AnyCodable]`, not `[Any]` /
            // `[String]` — the latter silently fail and we
            // end up with an empty `controlledUDIDs`, which
            // breaks the lockout. Also defend against the
            // case where the daemon happens to decode straight
            // to `[String]` (depends on JSON path).
            controlledUDIDs = parseUDIDList(event.params["udids"])
        case "event.sync_mode":
            if let b = unwrapBool(event.params["sync"]) {
                syncModeActive = b
            }
        default:
            break
        }
    }

    /// Map daemon-emitted `event.wifi_pair_progress` payloads to the
    /// observable `pairProgress` state. Stages map to a percentage so
    /// the GUI can render a smooth ProgressView; "done"/"failed" clear
    /// to nil so the spinner button reverts to its idle label.
    private func applyPairProgressEvent(_ params: [String: AnyCodable]) {
        let stage = stringValue(params["stage"]) ?? ""
        let message = stringValue(params["message"]) ?? ""
        switch stage {
        case "done", "failed":
            pairProgress = nil
        case "":
            return
        default:
            pairProgress = PairProgress(stage: stage, message: message)
        }
    }

    private func applyPositionEvent(_ params: [String: AnyCodable]) {
        guard let lat = doubleValue(params["lat"]),
              let lng = doubleValue(params["lng"])
        else { return }
        let eventUDID = stringValue(params["udid"])
        let coord = Coordinate(lat: lat, lng: lng)

        // Always record per-device, regardless of which device is
        // currently selected. The dict-backed setter only fires
        // the chip refresh when the event's udid IS the selected
        // device, so non-selected devices update silently in the
        // background — switching to them later shows their last
        // known location instantly without a daemon round-trip.
        if let udid = eventUDID {
            setSimulatedLocation(coord, for: udid)
        } else if let selected = selectedUDID {
            setSimulatedLocation(coord, for: selected)
        }

        // v1.11.2 round 8 perf fix: map-follow loop fires from here
        // (state-layer) instead of via .onChange(of: simulatedLocation)
        // on MainView. The view-layer observer was invalidating the
        // entire MainView body 10 Hz, fanning out to every .sheet /
        // .toolbar / .onChange modifier and pinning multi-thread
        // SwiftUI AttributeGraph at high CPU. Driving pendingMapFly
        // here keeps the per-tick work to a single property write
        // that only MapContainerView observes. Same trigger condition
        // as before: follow only when an "active" mode is running
        // and the event is for the selected device.
        if (eventUDID == nil || eventUDID == selectedUDID),
           shouldFollowSimulatedLocation {
            pendingMapFly = MapFlyRequest(
                coordinate: coord,
                spanMeters: 0,
                preserveZoom: true,
            )
        }

        // Live nav/random/joystick state only makes sense for the
        // CURRENTLY selected device — the UI bottom bar can't
        // render concurrent navs from two devices. Events for
        // non-selected devices update only the position dict
        // above; their navigator state is reconstructed when the
        // user switches selection (or just shown the next time
        // an event arrives for that device while selected).
        guard eventUDID == nil || eventUDID == selectedUDID else { return }

        if var nav = navigation {
            nav.currentLocation = coord
            if let cum = doubleValue(params["cumulative_m"]),
               nav.distanceM > 0 {
                // v1.11.2 round 11 (T24 fix): in dwell mode the
                // daemon's cumulative_m is only for the CURRENT leg
                // but nav.distanceM is now the FULL trip distance,
                // so we add the prior-leg accumulator and divide by
                // total. Non-dwell mode falls through to the original
                // calc (cum and distanceM are both whole-trip).
                nav.progress = max(0, min(1, cum / nav.distanceM))
            }
            if let eta = doubleValue(params["eta_s"]), !nav.isPaused {
                // v1.11.2: guard !isPaused so the displayed ETA
                // freezes while paused even if daemon keeps ticking.
                // dwellAdjustedEta is a no-op when dwellContext==nil;
                // in the new DwellMonitor path the daemon reports the
                // full-route eta_s so we use it directly.
                nav.etaSeconds = dwellAdjustedEta(currentLegEta: eta, from: coord)
                nav.etaRefAt = Date()
            }
            navigation = nav
            // DwellMonitor: trigger a pause/resume dwell at each
            // stop when the simulated position arrives within
            // thresholdM. Only fires when moving (not user-paused).
            if var dmon = dwellMonitor {
                if dmon.isDwelling || nav.state != .moving || dmon.nextIndex >= dmon.stops.count {
                    dwellLog("[DwellMonitor] BLOCKED: isDwelling=\(dmon.isDwelling) state=\(nav.state) idx=\(dmon.nextIndex)/\(dmon.stops.count)")
                } else {
                    let target = dmon.stops[dmon.nextIndex]
                    let loc = CLLocation(latitude: coord.lat, longitude: coord.lng)
                    let tgt = CLLocation(latitude: target.lat, longitude: target.lng)
                    let dist = loc.distance(from: tgt)
                    dwellLog("[DwellMonitor] check: idx=\(dmon.nextIndex) dist=\(String(format:"%.1f",dist))m threshold=\(dmon.thresholdM)m pos=(\(String(format:"%.5f",coord.lat)),\(String(format:"%.5f",coord.lng)))")
                    if dist < dmon.thresholdM {
                        dwellLog("[DwellMonitor] FIRED idx=\(dmon.nextIndex)")
                        dmon.isDwelling = true
                        dwellMonitor = dmon
                        let snap = dmon
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.pauseNavigation(udid: snap.udid)
                            try? await Task.sleep(for: .seconds(snap.dwellSeconds))
                            guard self.dwellMonitor != nil else { return }
                            await self.resumeNavigation(udid: snap.udid)
                            if var dm = self.dwellMonitor {
                                dm.isDwelling = false
                                dm.nextIndex += 1
                                if dm.nextIndex >= dm.stops.count {
                                    // All intermediate stops dwelled. The route
                                    // continues to the last stop; idle event
                                    // handles the final dwell + lap logic.
                                    self.dwellMonitor = nil
                                    return
                                }
                                self.dwellMonitor = dm
                            }
                        }
                    }
                }
            }
        } else if stringValue(params["state"]) == "moving",
                  let distanceM = doubleValue(params["distance_m"]),
                  let etaS = doubleValue(params["eta_s"]) {
            // v1.10.8 self-healing: resurrect navigation from a
            // position-update payload when it's nil but the daemon
            // reports state="moving". This catches the race where
            // a stale `state="idle"` from a previous handler's
            // `_stop_all_movement` (or any other source) clears
            // `navigation` AFTER the navigate-RPC reply already set
            // it up. Without this fallback the BottomBar ETA panel
            // silently disappears for the rest of the route even
            // though the daemon keeps playing — observed by users
            // as "有機會點完路線下方狀態欄消失".
            //
            // Position events ship the full Navigator.status JSON
            // (state / profile / speed_mps / distance_m / eta_s /
            // progress / cumulative_m), so we can fully reconstruct
            // NavigationVM. `routeCoordinates` isn't actually read
            // by BottomBar — the on-map polyline comes from
            // `activeRoute`, so empty is fine here.
            let profileStr = stringValue(params["profile"]) ?? travelProfile.rawValue
            let profile = TravelProfile(rawValue: profileStr) ?? travelProfile
            let speedMps = doubleValue(params["speed_mps"])
                ?? customSpeedMps
                ?? profile.defaultSpeedMps
            let cumulativeM = doubleValue(params["cumulative_m"]) ?? 0
            let progress: Double = {
                if let p = doubleValue(params["progress"]) { return max(0, min(1, p)) }
                if distanceM > 0 { return max(0, min(1, cumulativeM / distanceM)) }
                return 0
            }()
            navigation = NavigationVM(
                state: .moving,
                profile: profile,
                speedMps: speedMps,
                routeCoordinates: [],
                distanceM: distanceM,
                etaSeconds: dwellAdjustedEta(currentLegEta: etaS, from: coord),
                currentLocation: coord,
                progress: progress,
                laps: max(1, routeLaps),
                // Preserve the original start time — position events rebuild
                // NavigationVM on every tick; a fresh Date() here would reset
                // the elapsed-time counter every second.
                startedAt: navigation?.startedAt ?? Date()
            )
        }
        if var rw = randomWalk {
            rw.current = coord
            if let s = doubleValue(params["speed_mps"]) { rw.speedMps = s }
            if let d = doubleValue(params["distance_traveled_m"]) { rw.distanceTraveledM = d }
            if let path = coordinateArray(params["planned_path"]) {
                rw.plannedPath = path
            }
            randomWalk = rw
        }
        if var js = joystick {
            js.current = coord
            if let h = doubleValue(params["heading_deg"]) { js.headingDeg = h }
            if let s = doubleValue(params["speed_mps"]) {
                js.speedMps = s
                js.isMoving = s > 0
            }
            joystick = js
        }
    }

    /// Decode a `[{"lat": Double, "lng": Double}, ...]` blob coming back
    /// over JSON-RPC. Returns nil if the wrapped value isn't an array.
    private func coordinateArray(_ wrapped: AnyCodable?) -> [Coordinate]? {
        guard let arr = wrapped?.value as? [AnyCodable] else { return nil }
        var out: [Coordinate] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            guard let dict = item.value as? [String: AnyCodable] else { continue }
            guard let lat = doubleValue(dict["lat"]),
                  let lng = doubleValue(dict["lng"]) else { continue }
            out.append(Coordinate(lat: lat, lng: lng))
        }
        return out
    }

    private func applyStateEvent(_ params: [String: AnyCodable]) {
        // Random walk state events also flow through here. They carry a
        // refreshed planned_path roughly every five minutes, so the map
        // can redraw the upcoming polyline as the walker rolls forward.
        if var rw = randomWalk {
            if let path = coordinateArray(params["planned_path"]) {
                rw.plannedPath = path
                randomWalk = rw
            }
            if let s = stringValue(params["state"]), s == "stopped" {
                randomWalk = nil
            }
        }

        guard let stateRaw = stringValue(params["state"]) else { return }
        let mapped: NavigationVM.State?
        switch stateRaw {
        case "moving":  mapped = .moving
        case "paused":  mapped = .paused
        case "idle":    mapped = nil          // navigation is over
        case "stopped": mapped = nil
        default:        mapped = nil
        }

        // v1.9 route-complete alert. Fires when we had an active
        // navigation that was MOVING or PAUSED, and the daemon now
        // says "idle" — i.e. the runner reached the end of its
        // polyline. "stopped" means the user explicitly cancelled,
        // which doesn't merit a celebration sound. We trigger BEFORE
        // we clear `navigation` below so the guard reads cleanly.
        let wasRunning = navigation?.state == .moving || navigation?.state == .paused

        // v1.10.7 auto-loop continuation. When state goes
        // moving/paused → idle (natural completion, NOT "stopped"
        // which is user-driven), and we still owe laps on the
        // current `loopContext`, fire the next teleport-and-
        // navigate. The route-complete ding and the `navigation =
        // nil` reset below are suppressed while another lap is in
        // flight so the BottomBar progress doesn't flicker between
        // laps.
        var willLoopAgain = false
        if stateRaw == "idle", wasRunning, var ctx = loopContext {
            if ctx.remainingLaps > 0 {
                ctx.remainingLaps -= 1
                loopContext = ctx
                willLoopAgain = true
                let snap = ctx
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Dwell at the last stop of this lap before teleporting back
                    // to the start. Only applies when the user enabled dwell for
                    // this route run (opt-in from StartRouteSheet).
                    if snap.allowDwell {
                        try? await Task.sleep(for: .seconds(Double(snap.dwellSecondsForRoute)))
                        guard self.loopContext != nil else { return }
                    }
                    await self.teleport(udid: snap.udid,
                                        lat: snap.routePoints[0].lat,
                                        lng: snap.routePoints[0].lng)
                    let stops = Array(snap.routePoints.dropFirst())
                    guard !stops.isEmpty else { return }
                    let savedLaps = self.routeLaps
                    let savedStraight = self.useStraightLine
                    self.routeLaps = 1
                    self.useStraightLine = true
                    defer {
                        self.routeLaps = savedLaps
                        self.useStraightLine = savedStraight
                    }
                    await self.navigate(udid: snap.udid,
                                        through: stops,
                                        profile: snap.profile,
                                        speed: snap.speed,
                                        allowDwell: snap.allowDwell,
                                        dwellOverride: snap.allowDwell ? true : nil,
                                        dwellSecondsOverride: snap.allowDwell ? snap.dwellSecondsForRoute : nil,
                                        suppressDwellContext: true)
                }
            } else {
                loopContext = nil
            }
        }

        // Dwell at final stop + lap continuation. When the full route
        // reaches idle with a dwellContext active, sleep the dwell time
        // at the last stop, then either teleport-and-loop or finish.
        // Explicit Stop clears dwellContext in stopNavigation(), so the
        // Task's guard check exits immediately on user cancellation.
        var willDwellNext = false
        if stateRaw == "idle", wasRunning, let dctx = dwellContext {
            willDwellNext = true
            let snap = dctx
            let startCoord = dctx.allStops[0]
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(snap.dwellSeconds))  // dwell at last stop
                guard self.dwellContext != nil else { return }
                if snap.remainingDwellLaps > 0 {
                    var nextDctx = snap
                    nextDctx.remainingDwellLaps -= 1
                    nextDctx.currentLap += 1
                    self.dwellContext = nextDctx
                    // Clear navigation BEFORE teleport: teleportPositionOnly() causes
                    // the daemon to send state=idle (it stops the current route when
                    // repositioning), which would re-trigger this idle handler and
                    // fire a duplicate lap-continuation navigate(). By clearing
                    // navigation here, applyStateEvent's wasRunning check fails for
                    // any daemon idle that arrives during the teleport, preventing
                    // the double-navigate bug.
                    self.navigation = nil
                    await self.teleportPositionOnly(udid: snap.udid,
                                                   lat: startCoord.lat,
                                                   lng: startCoord.lng)
                    guard self.dwellContext != nil else { return }
                    try? await Task.sleep(for: .seconds(snap.dwellSeconds))  // dwell at stop1
                    guard self.dwellContext != nil else { return }
                    let savedStraight = self.useStraightLine
                    self.useStraightLine = snap.useStraightLine
                    defer { self.useStraightLine = savedStraight }
                    // Origin is already at allStops[0] (teleported above);
                    // pass the remaining stops so waypoints don't duplicate stop1.
                    await self.navigate(udid: snap.udid,
                                        through: Array(snap.allStops.dropFirst()),
                                        profile: snap.profile,
                                        speed: snap.speed,
                                        isLapContinuation: true)
                } else {
                    self.dwellContext = nil
                    self.dwellMonitor = nil
                    self.navigation = nil
                    if self.alertSoundEnabled {
                        Task { @MainActor in AlertSoundService.playRouteComplete() }
                    }
                }
            }
        }

        if stateRaw == "idle", wasRunning, alertSoundEnabled, !willLoopAgain, !willDwellNext {
            Task { @MainActor in AlertSoundService.playRouteComplete() }
        }

        if let mapped {
            if var nav = navigation {
                nav.state = mapped
                navigation = nav
            }
        } else if !willLoopAgain, !willDwellNext {
            navigation = nil
        }
        // When `willLoopAgain` or `willDwellNext` is true we leave
        // `navigation` alone: the next `navigate(...)` call from the
        // queued Task will overwrite it with the fresh leg's state.
        // Clearing it here would make the BottomBar progress flicker
        // between legs during a dwell sequence.
    }

    /// In dwell mode the daemon only knows about the current single-
    /// leg navigate, so its emitted `eta_s` covers just that leg.
    /// This helper extends that to the full remaining multi-stop
    /// journey: current-leg ETA + every still-pending leg's haversine
    /// straight-line time + a dwell pause at each stop. Returns the
    /// raw leg ETA unchanged when no dwell sequence is active.
    private func dwellAdjustedEta(currentLegEta: Double, from currentCoord: Coordinate) -> Double {
        guard let dctx = dwellContext else { return currentLegEta }
        // Remaining intermediate pauses (DwellMonitor hasn't fired yet)
        // + 1 for the final stop (handled by idle event).
        let pendingIntermediate = dwellMonitor.map { $0.stops.count - $0.nextIndex } ?? 0
        let pendingPauses = pendingIntermediate + 1
        return currentLegEta + Double(pendingPauses * dctx.dwellSeconds)
    }

    private func doubleValue(_ wrapped: AnyCodable?) -> Double? {
        guard let wrapped else { return nil }
        if let d = wrapped.value as? Double { return d }
        if let i = wrapped.value as? Int { return Double(i) }
        return nil
    }

    private func stringValue(_ wrapped: AnyCodable?) -> String? {
        guard let wrapped else { return nil }
        return wrapped.value as? String
    }

    /// Decode `["A", "B"]` out of an AnyCodable-wrapped JSON
    /// array, no matter which intermediate representation the
    /// decoder picked. Returns an empty Set on any failure so
    /// the caller doesn't have to handle nil.
    private func parseUDIDList(_ wrapped: AnyCodable?) -> Set<String> {
        guard let wrapped else { return [] }
        if let strs = wrapped.value as? [String] {
            return Set(strs)
        }
        if let codables = wrapped.value as? [AnyCodable] {
            return Set(codables.compactMap { $0.value as? String })
        }
        if let any = wrapped.value as? [Any] {
            return Set(any.compactMap { $0 as? String })
        }
        return []
    }

    /// Extract a Bool from an AnyCodable-wrapped JSON value,
    /// accepting the NSNumber bridge and a numeric 0/1 fallback.
    /// Used by `event.phone_session` / `event.sync_mode` where
    /// the wire format is a plain JSON `true` / `false` but
    /// Foundation's decoder sometimes hands us an NSNumber.
    private func unwrapBool(_ wrapped: AnyCodable?) -> Bool? {
        guard let wrapped else { return nil }
        if let b = wrapped.value as? Bool { return b }
        if let n = wrapped.value as? NSNumber { return n.boolValue }
        if let i = wrapped.value as? Int { return i != 0 }
        return nil
    }

    // MARK: - Helpers

    /// Wait for the daemon socket to become *responsive*, not just to
    /// appear on disk. A stale socket file from a crashed previous daemon
    /// satisfies `fileExists` but throws ECONNREFUSED on connect — so
    /// polling on existence alone caused bootstrap() to immediately
    /// attempt connect() against a dead socket, fail with errno=61, and
    /// land in the catch block with a red error chip but no actionable
    /// path forward (see the v1.11.2 connect-failure fix). Probing with
    /// connect()+close() each tick ensures we only return true once a
    /// real listener is bound.
    private static func waitForSocket(path: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if DaemonLifecycle.isSocketResponsive(at: path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

/// One row of `wifi.discover` output: an iPhone (or candidate IP) the
/// daemon found on the LAN. UDID is intentionally absent — we don't
/// know which paired device is at this IP until `wifi.connect_ip`
/// runs the pair-verify candidate sweep on the daemon side.
/// Mirrors the daemon's `/api/phone/info` response. The PIN is
/// regenerated on every daemon launch (and on demand via
/// `rotatePhoneControlPIN`), so this struct is short-lived and not
/// persisted across sessions.
struct PhoneControlInfo: Codable, Hashable, Sendable {
    let url: String
    let pin: String
    let lan_ip: String
    let port: Int
}

struct WiFiCandidate: Codable, Identifiable, Hashable, Sendable {
    let ip: String
    let port: Int
    let host: String
    let name: String
    /// "mdns" for Bonjour-discovered, "tcp_scan" for /24 fallback.
    let method: String

    var id: String { "\(ip):\(port)" }
}

/// Identifies which device the WiFi-connect selection sheet is open
/// for. `Identifiable` so the sheet can be presented via SwiftUI's
/// `.sheet(item:content:)` modifier — that pattern auto-handles the
/// "set to nil to dismiss" lifecycle without extra state plumbing.
struct WiFiConnectSheetTarget: Identifiable, Hashable, Sendable {
    let udid: String
    var id: String { udid }
}

/// Two-stage pairing progress fed by `event.wifi_pair_progress`. The
/// stage strings come straight from the daemon and are stable enough
/// to switch on for UI labels / fractions.
struct PairProgress: Hashable, Sendable {
    let stage: String
    let message: String

    /// 0.0–1.0 for ProgressView. Stages map to round numbers so the
    /// bar moves monotonically.
    var fraction: Double {
        switch stage {
        case "usbmux_query":   return 0.10
        case "usb_pairing":    return 0.30
        case "tunnel_setup":   return 0.55
        case "remote_pairing": return 0.80
        default:               return 0.50
        }
    }
}

/// Decoded `DeviceInfo` from `device.list`. Mirrors the daemon's
/// `models.DeviceInfo` shape.
struct DeviceVM: Codable, Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    let ios_version: String
    let transport: String
    let connected: Bool
    let developer_mode: Bool?    // nil == unknown / not queryable
    /// Every transport usbmuxd currently sees this UDID on. Always
    /// contains the active `transport`. May be empty for legacy
    /// daemons that don't yet report this field.
    let transports: [String]?
    /// True if `~/.pymobiledevice3/remote_<UDID>.plist` exists — i.e.
    /// the M-style WiFi pairing ritual has already run for this device
    /// and the GUI should hide / soften its "Pair for WiFi" button.
    /// nil for legacy daemons (< v0.2.9) that don't yet report it.
    let wifi_paired: Bool?
    /// When connected via WiFi (direct-IP RemotePairing), the peer
    /// endpoint the tunnel goes to. Lets the GUI's WiFi-Devices
    /// candidate list know exactly which row to flip into "Connected"
    /// state instead of all rows lighting up. nil for USB sessions
    /// or legacy daemons (< v0.2.10).
    let peer_ip: String?
    let peer_port: Int?

    var id: String { udid }
    var iosVersion: String { ios_version }
    var isUSB: Bool { transport == "usb" }
    /// True only if we know for certain dev mode is OFF. nil → don't show
    /// the warning, since some unpaired devices report nil even when on.
    var developerModeNeedsAttention: Bool { developer_mode == false }

    var availableTransports: Set<String> {
        Set(transports ?? [transport])
    }
    var supportsUSB: Bool { availableTransports.contains("usb") }
    var supportsWiFi: Bool { availableTransports.contains("network") }
    /// Convenience: the pair record exists on disk. Daemons older than
    /// v0.2.9 don't send this field; we return false in that case so
    /// the button stays visible.
    var isWiFiPaired: Bool { wifi_paired ?? false }

    /// Short label for the device's dev-mode state. Tri-state because an
    /// unpaired/untrusted device can return nil even when dev mode is on.
    /// Uses Bundle.main (the default for `String(localized:)`); the
    /// .lproj files are copied to `.app/Contents/Resources/` by
    /// package-app.sh, where Bundle.main finds them. Do NOT route
    /// these strings through the SwiftPM-generated module bundle —
    /// see the comment block in Scripts/package-app.sh for why the
    /// executable-target accessor crashes the packaged app on any
    /// machine other than the developer's own.
    var developerModeLabel: String {
        switch developer_mode {
        case .some(true):
            return String(localized: "Dev Mode: ON",
                          comment: "Device chip label — Developer Mode is enabled")
        case .some(false):
            return String(localized: "Dev Mode: OFF",
                          comment: "Device chip label — Developer Mode is disabled")
        case .none:
            return String(localized: "Dev Mode: unknown",
                          comment: "Device chip label — couldn't query Developer Mode state")
        }
    }
}

struct Coordinate: Hashable, Sendable, Codable {
    let lat: Double
    let lng: Double
}

/// Which inline panel the user has open in the Movement Modes
/// sidebar section. `MovementModesSection` reads + writes this via
/// `AppState.activeMovementMode`; other code paths (map-click
/// handler, etc.) read it to know whether map clicks should add
/// stops, joystick input should fire, etc.
enum MovementMode: String, Hashable, Sendable {
    case joystick
    case randomWalk
    case multiStop
    case goldDitto
}

/// Carrier for "we just parsed a GPX file, now ask the user what to
/// name it" — handed to RouteEditSheet which then calls
/// `AppState.saveImportedRoute` once the user confirms.
struct PendingRouteImport: Hashable, Sendable {
    /// Filename stem (no extension). Pre-fills the name field so a
    /// user who just wants to keep the GPX-supplied name can hit Save.
    let suggestedName: String
    /// Full coordinate list, in source order. Untouched — no
    /// downsampling, even for thousand-point tracks.
    let coordinates: [Coordinate]
}

/// Base map source the user can pick from the floating layer button.
/// Apple Maps is a special case — it's MKMapView's NATIVE rendering
/// (no tile overlay), so the MapContainerView coordinator handles the
/// switch by removing all tile overlays and flipping `mapType`. The
/// raster sources are plain XYZ tile URL templates fed into
/// MKTileOverlay.
enum MapTileLayer: String, CaseIterable, Identifiable, Sendable {
    /// Native MapKit rendering — vector, free, dark-mode aware.
    case appleStandard
    /// Native MapKit satellite — Apple's imagery.
    case appleSatellite
    /// OSM raster tiles. The original LociiGhost default.
    case openStreetMap
    /// Carto Voyager — softer palette, easier on the eyes.
    case cartoVoyager
    /// ESRI satellite imagery (raster). Useful when Apple Satellite
    /// has no detail at the zoom level (rural Asia, smaller cities).
    case esriSatellite

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .appleStandard:  return LocalizedStringKey("Apple Maps")
        case .appleSatellite: return LocalizedStringKey("Apple Satellite")
        case .openStreetMap:  return LocalizedStringKey("OpenStreetMap")
        case .cartoVoyager:   return LocalizedStringKey("Carto Voyager")
        case .esriSatellite:  return LocalizedStringKey("ESRI Satellite")
        }
    }

    /// SF Symbol shown in the layer-picker rows.
    var symbol: String {
        switch self {
        case .appleStandard:  return "map"
        case .appleSatellite: return "globe.americas.fill"
        case .openStreetMap:  return "map.circle"
        case .cartoVoyager:   return "map.fill"
        case .esriSatellite:  return "globe"
        }
    }

    /// XYZ template for raster sources. nil for the Apple-rendered
    /// cases — those use MKMapType, not a tile overlay.
    var tileURLTemplate: String? {
        switch self {
        case .appleStandard, .appleSatellite:
            return nil
        case .openStreetMap:
            return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .cartoVoyager:
            return "https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png"
        case .esriSatellite:
            // ESRI's tile scheme is {z}/{y}/{x}, not {z}/{x}/{y}.
            return "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
        }
    }
}

struct MapFlyRequest: Hashable, Sendable {
    let id: UUID = UUID()
    let coordinate: Coordinate
    /// Side length of the displayed region in meters. Smaller = more
    /// zoomed in.
    let spanMeters: Double
    /// When true, ignore `spanMeters` and shift only the centre,
    /// preserving the user's current zoom. Used by the
    /// follow-puck-during-movement loop so 1 Hz position updates
    /// don't repeatedly fight whatever zoom level the user picked.
    var preserveZoom: Bool = false
}

/// Travel profile presets. Backend mirrors these in `routing.PROFILES`
/// and `handlers.SPEED_PRESETS`.
enum TravelProfile: String, CaseIterable, Identifiable, Sendable {
    case walking, cycling, driving

    var id: String { rawValue }

    /// Plain-String label for places that need a `String` (e.g. log
    /// lines, accessibility values). Resolves against `Locale.current`
    /// at call time. UI surfaces should prefer `labelKey` instead so
    /// the rendered Text follows the env locale (and therefore the
    /// language picker) on every state change.
    var label: String {
        switch self {
        case .walking:
            return String(localized: "Walking",
                          comment: "Travel profile name")
        case .cycling:
            return String(localized: "Cycling",
                          comment: "Travel profile name")
        case .driving:
            return String(localized: "Driving",
                          comment: "Travel profile name")
        }
    }

    /// `LocalizedStringKey` flavour for use inside SwiftUI `Label(...)`,
    /// `Picker(...)` items, etc. Unlike the `String` `label` accessor,
    /// this one is re-evaluated by SwiftUI against the active env
    /// locale on every render, so flipping the language picker
    /// updates segmented-control labels live.
    var labelKey: LocalizedStringKey {
        switch self {
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .driving: return "Driving"
        }
    }

    var symbol: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        }
    }

    /// m/s — must match the daemon's `SPEED_PRESETS`.
    var defaultSpeedMps: Double {
        switch self {
        case .walking: return 1.4    // ~5 km/h
        case .cycling: return 5.5    // ~20 km/h
        case .driving: return 11.1   // ~40 km/h
        }
    }

    var defaultSpeedKmh: Double { defaultSpeedMps * 3.6 }
}

/// Snapshot of the parameters needed to replay a route on auto-loop.
/// Owned by `AppState.loopContext`; populated by `runRoute(lapCount:)`
/// when looping is requested, drained by `applyStateEvent` on each
/// natural "idle" transition until `remainingLaps` hits zero.
///
/// We snapshot `routePoints` (not the SwiftData `Route` itself) so a
/// concurrent edit / delete of the underlying record can't crash the
/// loop. `remainingLaps == Int.max` is the sentinel for "until user
/// presses Stop".
struct LoopContext: Sendable, Equatable {
    let routePoints: [Coordinate]
    let udid: String
    let profile: TravelProfile
    let speed: Double
    var remainingLaps: Int
    /// Whether dwell pauses are enabled for this route run (opt-in per-execution
    /// in StartRouteSheet; does NOT read the global dwellEnabled toggle so that
    /// multi-stop dwell setting doesn't leak into route playback).
    var allowDwell: Bool = false
    /// Seconds to pause at each intermediate waypoint and at the end of each lap
    /// before looping (only meaningful when allowDwell == true).
    var dwellSecondsForRoute: Int = 5
}

/// Per-stop dwell sequence (Feat #3 / v1.11.0). When the user enables
/// "Dwell at each stop", the public `navigate(udid:through:)` splits
/// the multi-stop request into N single-leg navigates and stores the
/// remaining queue here. `applyStateEvent` consumes one entry on each
/// natural idle, sleeps `dwellSeconds`, then fires the next leg. The
/// daemon is unaware — it just sees a normal sequence of single-target
/// navigates separated by the dwell delays.
struct DwellContext: Sendable, Equatable {
    let udid: String
    let profile: TravelProfile
    let speed: Double
    let dwellSeconds: Int
    /// Snapshot of `useStraightLine` at dwell start so every lap's
    /// navigate() call uses the same routing mode the user chose.
    var useStraightLine: Bool = false
    /// Full stop list; preserved so lap restarts replay the same route.
    var allStops: [Coordinate] = []
    /// Total laps requested (1 = single trip).
    var totalLaps: Int = 1
    /// 1-indexed current lap number.
    var currentLap: Int = 1
    /// Laps remaining AFTER the current one. 0 = this is the last lap.
    var remainingDwellLaps: Int = 0
}

/// Position-based dwell pause tracker. The full multi-stop route runs as
/// ONE navigate RPC; this struct drives `location.pause` / `location.resume`
/// when the simulated position arrives near each waypoint in order.
struct DwellMonitor: Sendable {
    let udid: String
    /// Route-snapped trigger coordinates (intermediate stops only; the
    /// last stop is handled by the idle event, not proximity detection).
    let stops: [Coordinate]
    var nextIndex: Int = 0
    /// True while a pause+sleep+resume Task is in flight — prevents
    /// a second trigger on the same stop from consecutive 1 Hz events.
    var isDwelling: Bool = false
    let dwellSeconds: Int
    /// Proximity radius in metres. 35 m gives enough margin for the
    /// gap between a user's off-road drop and the OSRM road-snap.
    let thresholdM: Double
}

/// Multi-stop lap tracking. Set by navigate() when routeLaps > 1.
/// applyStateEvent teleports to stops[0] and fires the next lap on
/// natural idle, mirroring the loopContext pattern for route replay.
struct MultiStopLapContext: Sendable {
    let udid: String
    let stops: [Coordinate]
    let profile: TravelProfile
    let speed: Double
    var remainingLaps: Int
}

struct NavigationVM: Sendable, Equatable {
    enum State: Sendable, Equatable { case moving, paused }

    var state: State
    var profile: TravelProfile
    var speedMps: Double
    var routeCoordinates: [Coordinate]
    var distanceM: Double
    var etaSeconds: Double
    var currentLocation: Coordinate
    var progress: Double            // 0...1
    var laps: Int = 1               // 1 = single trip, 2+ = looped
    /// Dwell-mode lap display. When the App manually orchestrates laps via
    /// DwellContext (multi-stop dwell), progress-based currentLap is wrong
    /// because `laps` is clamped to 1 (daemon runs one lap at a time).
    /// These fields let BottomBar show the correct lap counter in dwell mode.
    /// 0 = not in dwell-lap mode; use progress-based currentLap / laps instead.
    var dwellCurrentLap: Int = 0
    var dwellTotalLaps: Int = 0
    /// Wall-clock instant the trip started. Preserved across position-event
    /// NavigationVM rebuilds so the elapsed counter doesn't reset every tick.
    var startedAt: Date = .now
    /// Wall-clock instant when `etaSeconds` was last written.
    var etaRefAt: Date = .now
    /// Wall-clock instant when pause was triggered. Set by
    /// `pauseNavigation`, cleared on resume. Used by ElapsedTimerChip
    /// to freeze the elapsed counter at the right value while paused.
    var pausedAt: Date? = nil

    var isPaused: Bool { state == .paused }
    /// Distance of one lap of the closed-loop route (or the full route
    /// when laps == 1). Used by the BottomBar to render a "Lap 2 / 5"
    /// badge instead of just a single accumulating progress bar.
    var lapDistanceM: Double { laps > 0 ? distanceM / Double(laps) : distanceM }
    /// Currently-walking lap, 1-indexed. Stays at 1 for single trips.
    var currentLap: Int {
        guard laps > 1, lapDistanceM > 0 else { return 1 }
        let traveled = distanceM * progress
        return min(laps, Int(traveled / lapDistanceM) + 1)
    }
}

struct RandomWalkVM: Sendable, Equatable {
    var center: Coordinate
    var radiusM: Double
    var current: Coordinate
    var speedMps: Double
    var distanceTraveledM: Double
    var isMoving: Bool
    /// Pre-generated upcoming targets that the daemon will walk through
    /// in order. The map renders this as a dashed polyline so the user
    /// sees what the iPhone will do over the next ~5 minutes.
    var plannedPath: [Coordinate] = []
}

struct JoystickVM: Sendable, Equatable {
    var current: Coordinate
    var headingDeg: Double
    var speedMps: Double
    var isMoving: Bool
}
