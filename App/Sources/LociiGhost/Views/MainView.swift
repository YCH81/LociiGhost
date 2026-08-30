import SwiftUI
import LociiGhostCore

struct MainView: View {
    @Environment(AppState.self) private var state
    /// Language preference plumbed down from LociiGhostApp's
    /// @AppStorage so AppHeaderBar can flip it without each view
    /// reaching back into the storage layer.
    @Binding var appLanguage: AppLanguage
    /// Whether the sidebar column is showing. The toolbar's
    /// built-in sidebar-toggle button (NSSplitViewController hands
    /// us one for free with `NavigationSplitView`) writes to this
    /// binding — passing `.constant(.all)` would make every toggle
    /// a silent no-op, which is the bug we just fixed.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Drives the "are you sure?" alert when the user taps the
    /// sync-mode toggle on the lockout overlay.
    @State private var showSyncConfirm: Bool = false

    var body: some View {
        @Bindable var state = state
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                // Lock the sidebar column at ≥280pt. Without this,
                // NavigationSplitView lets the user drag the splitter
                // narrower than the Sidebar's internal `.frame(minWidth:)`
                // can stop, which char-wraps device names like
                // "iPhone (Wi-Fi)" into vertical fragments.
                // min 280 covers "iPhone (Wi-Fi)" without truncating;
                // max 310 keeps the main pane ≥ ~1000pt at the current
                // window minWidth (1320) so TopStatusBar never overflows.
                // Widening past 310 isn't useful — sidebar content is
                // already laid out for ~280-300pt; extra width just
                // steals from the map.
                .navigationSplitViewColumnWidth(min: 280, ideal: 295, max: 310)
        } detail: {
            VStack(spacing: 0) {
                // v1.11.2: .layoutPriority(1) on both fixed bars ensures
                // SwiftUI allocates their natural heights BEFORE giving
                // the remaining space to the map ZStack. Without this,
                // MapContainerView (NSViewRepresentable) occasionally
                // claims the full VStack height during a NavigationSplitView
                // layout pass on macOS Tahoe — compressing TopStatusBar to
                // 0 pt and leaving BottomBar empty. The map ZStack has no
                // priority set (defaults to 0) so it always gets the remainder.
                AppHeaderBar(appLanguage: $appLanguage)
                    .layoutPriority(1)
                TopStatusBar()
                    .layoutPriority(1)
                ZStack(alignment: .topLeading) {
                    // Hybrid dispatcher: SwiftUI native `Map` for Apple-
                    // rendered layers (much smoother on idle pan — the
                    // NSViewRepresentable bridging overhead disappears),
                    // MapContainerView for the raster tile sources that
                    // SwiftUI Map doesn't support (OSM / Carto / ESRI).
                    // Both share AppState so annotations, route line,
                    // bookmark overlay etc. flow through whichever path
                    // is currently active.
                    Group {
                        if state.mapTileLayer.usesNativeAppleMap {
                            NativeMapView()
                        } else {
                            MapContainerView()
                        }
                    }
                    .ignoresSafeArea(edges: .top)
                        // Block hit-testing while the selected
                        // iPhone is disconnected. The grey overlay
                        // below also catches mouse events, but
                        // belt-and-suspenders here keeps map
                        // gestures (pan/zoom/click) totally
                        // inert even if the overlay's z-order
                        // ever shifts.
                        .allowsHitTesting(!state.selectedDeviceIsDisconnected
                                          && !state.shouldShowPhoneLockout)

                    if state.shouldShowPhoneLockout {
                        phoneLockoutOverlay
                            .transition(.opacity)
                    } else if state.selectedDeviceIsDisconnected {
                        disconnectedOverlay
                            .transition(.opacity)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        // Top strip: search bar centred between the
                        // left scale-indicator reserve and the right
                        // cluster (recenter / recent places / layer
                        // picker). Earlier versions anchored the
                        // search bar hard-left (immediately after
                        // the 160 pt scale reserve), which still
                        // overlapped the "0 — 2.5 km" ruler at some
                        // zoom levels and looked off-balance on
                        // wider windows. The two flex spacers
                        // distribute remaining horizontal space
                        // equally so the search bar tracks the
                        // midpoint of the *usable* map area as the
                        // window resizes — never colliding with the
                        // scale indicator on the left or the right
                        // cluster on the right.
                        HStack(alignment: .top, spacing: 12) {
                            Spacer().frame(width: 160)
                            Spacer(minLength: 12)
                            MapSearchBar()
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 8) {
                                QuickRecenterButton()
                                RecentPlacesButton()
                                MapLayerPicker()
                            }
                            .padding(.trailing, 44)
                        }
                        Overlay()
                    }
                    .padding(12)
                }
                BottomBar()
                    .layoutPriority(1)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("LociiGhost")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DaemonStatusPill()
            }
        }
        // Drive route-preview refreshes from here so the view layer's
        // observation of `pendingStops` / `useStraightLine` does the work
        // — `didSet` on those properties wouldn't fire reliably under the
        // @Observable macro for in-place array mutations.
        .onChange(of: state.pendingStops) { _, _ in
            state.schedulePreviewRefresh()
        }
        .onChange(of: state.useStraightLine) { _, _ in
            state.schedulePreviewRefresh()
        }
        // Selection change flips which device's slot the
        // simulatedLocation computed property reads from (the
        // dict is keyed on selectedUDID). The chip refresh
        // task lives behind setters that fire when their
        // *value* changes — not when the selection flips — so
        // we kick the scheduler explicitly here. Cheap.
        //
        // We also fly the map to the new device's known
        // simulated location, if any: switching back to a
        // device that was previously teleported should land
        // the camera right on it, not leave it on the previous
        // device's view. Per-device live nav/joystick state
        // still gets cleared (those singletons can't represent
        // multiple devices); the daemon will re-emit if the
        // newly-selected device has anything active.
        .onChange(of: state.selectedUDID) { oldSelection, newSelection in
            state.refreshWeatherAndTzNow()
            // v1.11.2 round 17: per-device memory for activeMovementMode
            // and pendingStops. Before this, switching from iPhone A
            // (staged for multi-stop) to Map / iPhone B and back left
            // A's staging gone — `activeMovementMode` and `pendingStops`
            // are single globals at the AppState level, so any
            // intervening selection that wrote to them clobbered A's
            // state. We snapshot on leave + restore on arrive so each
            // device gets its own private slot.
            if let leaving = oldSelection {
                state.snapshotModeAndStops(forLeaving: leaving)
            }
            // Wipe the remaining per-singleton nav state (NavigationVM /
            // JoystickVM) BEFORE restore so the arriving device starts
            // from a clean slate. RandomWalkVM is now managed by
            // snapshotModeAndStops / restoreModeAndStops (v1.13.1 fix
            // for "switch away + back → walker centre drifts onto
            // current position"), so we deliberately don't nil it
            // here — restoreModeAndStops writes the saved value (or
            // nil if no walker was running on the arriving device).
            state.navigation = nil
            state.joystick = nil
            if let arriving = newSelection {
                state.restoreModeAndStops(forArriving: arriving)
            }
            if let coord = state.simulatedLocation {
                state.pendingMapFly = MapFlyRequest(
                    coordinate: coord,
                    spanMeters: 2_000,
                )
            }
            // We INTENTIONALLY don't clear `activeRoute` /
            // `activeWaypoints` / `activeDestination` on
            // selection change any more — those are per-device
            // (read from `tripsByDevice` keyed on selectedUDID).
            // Switching to iPhone B and back to A naturally
            // re-shows A's route.
        }
        // v1.11.2 round 8 perf fix: the map-follow trigger lives in
        // AppState.applyPositionEvent now (state-layer instead of
        // view-layer). Putting `.onChange(of: state.simulatedLocation)`
        // on this MainView body meant every 10 Hz position event
        // re-registered every .onChange / .sheet / .toolbar modifier
        // here, fanning out to every sub-view's dependency graph.
        // Round 7's MapFollowObserver attempt (.background sub-view)
        // accidentally compounded the loop and pinned CPU at 100%.
        // Driving pendingMapFly directly from applyPositionEvent
        // (the same code that updates simulatedLocation) bypasses
        // the view-layer observer entirely.
        // Sync-mode confirm. Triggered by the "Use both at once"
        // button on the lockout overlay. We warn the user that
        // running both UIs simultaneously can let the two
        // controllers fight each other; if that happens both
        // sides hitting Restore is the recovery path.
        .alert(
            Text("Use both at the same time?",
                 comment: "Sync-mode confirm dialog title"),
            isPresented: $showSyncConfirm,
        ) {
            Button(role: .cancel) {} label: {
                Text("Cancel")
            }
            Button {
                Task { await state.setSyncMode(true) }
            } label: {
                Text("Enable",
                     comment: "Sync-mode confirm — proceed")
            }
        } message: {
            Text("Mac and phone can both drive at the same time. If their actions clash and the iPhone's position gets out of sync, press Restore on BOTH sides and start over.",
                 comment: "Sync-mode confirm explanation")
        }
        // Route-start confirmation. Clicking a sidebar route parks it
        // in `routePendingConfirm`; this sheet is what actually turns
        // that into a teleport + navigate. v1.10.7 swapped the prior
        // `.alert(presenting:)` for a `.sheet` so the "Loop until I
        // stop" Toggle can live inline — SwiftUI's standard alert
        // doesn't accept inline controls.
        .sheet(isPresented: Binding(
            get: { state.routePendingConfirm != nil },
            set: { isOpen in
                if !isOpen { state.routePendingConfirm = nil }
            },
        )) {
            if let route = state.routePendingConfirm {
                StartRouteSheet(route: route)
            }
        }
        // v1.11.0 stop-preset "Save as" sheet. Triggered from the
        // bookmark-icon button in MultiStopPanel; asks the user for
        // a name then writes a `StopPreset` SwiftData row.
        .sheet(isPresented: Binding(
            get: { state.presetPendingSave },
            set: { state.presetPendingSave = $0 },
        )) {
            SavePresetSheet()
        }
        // Bookmark photo preview — custom overlay (not `.sheet`) so the
        // user can click the dimmed backdrop to dismiss. macOS sheets
        // don't dismiss on outside-click by default and the X-button
        // alone felt unfriendly. ZIndex keeps the overlay above
        // toolbar / sidebar so it sits on top of every floating
        // element. All bookmark-preview entry points (sidebar
        // photo button, manager sheet, map pin) funnel through
        // `state.mapPreviewingBookmark`, so this one overlay covers
        // them all.
        .overlay {
            if let bm = state.mapPreviewingBookmark {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.mapPreviewingBookmark = nil
                        }
                    BookmarkImageSheet(bookmark: bm) {
                        state.mapPreviewingBookmark = nil
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.regularMaterial),
                    )
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                    // Eat taps on the sheet itself so they don't bubble
                    // up to the backdrop and dismiss.
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { /* swallow */ }
                }
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        // v1.11.0 stop-preset "Load" confirmation sheet. Clicking a
        // preset row parks it here; the sheet then offers Display
        // Only / Teleport to First.
        .sheet(isPresented: Binding(
            get: { state.presetPendingLoad != nil },
            set: { isOpen in
                if !isOpen { state.presetPendingLoad = nil }
            },
        )) {
            if let preset = state.presetPendingLoad {
                LoadStopPresetSheet(preset: preset)
            }
        }
    }

    /// Frosted-grey panel that covers the map when the user
    /// selected an iPhone row that's currently offline. Carries
    /// no controls — just a clear "已斷線" message + an
    /// instruction to pick another device. Intercepts all hit
    /// events so even right-clicks (which would otherwise pop the
    /// map's context menu) are swallowed.
    private var phoneLockoutOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.92)
                .overlay(Color.black.opacity(0.18))
            VStack(spacing: 14) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right.circle.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                Text("Phone in control",
                     comment: "Mac map lockout — heading shown while phone-web session is active")
                    .font(.title2.weight(.semibold))
                Text("A phone is currently signed in via Phone Control. The Mac is paused while the phone is driving. Sign out from the phone, or press the button below to take control back.",
                     comment: "Mac map lockout — body explanation")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        Task { await state.forcePhoneLogout() }
                    } label: {
                        Label("Stop phone control",
                              systemImage: "xmark.circle.fill")
                            .padding(.horizontal, 6)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button {
                        showSyncConfirm = true
                    } label: {
                        Label("Use both at once",
                              systemImage: "arrow.left.arrow.right.circle")
                            .padding(.horizontal, 6)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5),
            )
            .shadow(color: Color.black.opacity(0.22), radius: 12, y: 4)
        }
        .contentShape(.rect)
        .onTapGesture { /* eat */ }
    }

    private var disconnectedOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.92)
                .overlay(Color.black.opacity(0.18))
            VStack(spacing: 12) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Disconnected",
                     comment: "Big centred label shown when the selected iPhone is offline")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("This iPhone isn't currently reachable. Reconnect it, or pick the **Map** entry in the sidebar to browse the map without a device.",
                     comment: "Helper text under the disconnected map overlay")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            .padding(24)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5),
            )
            .shadow(color: Color.black.opacity(0.2), radius: 10, y: 3)
        }
        // Swallow every gesture so the map underneath stays fully
        // inert even if `.allowsHitTesting` ever stops working.
        .contentShape(.rect)
        .onTapGesture { /* eat */ }
    }
}

private struct Sidebar: View {
    @Environment(AppState.self) private var state
    /// Devices is the only section without its own struct, so its
    /// collapse state lives here. Title row stays visible always so
    /// the user can find the section to expand again.
    @State private var devicesCollapsed: Bool = false

    var body: some View {
        @Bindable var state = state
        // Wrap the whole sidebar content in a ScrollView. Without
        // it, a power user expanding a Bookmarks category with
        // 70+ rows pushes the VStack past the window's height —
        // the sidebar then grows the NavigationSplitView's column,
        // shoving the detail-pane bars (header + status bar +
        // bottom bar) off-screen. A scrollview keeps the sidebar
        // bounded to its column's height and lets the user scroll
        // through their bookmarks instead.
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text("Devices").font(.headline)
                Spacer()
                Button {
                    Task { await state.refreshDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(4)
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help(LocalizedStringKey("Re-scan for connected devices"))
                Image(systemName: devicesCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                    .hoverHighlight(cornerRadius: 4, changesCursor: false)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            devicesCollapsed.toggle()
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Divider().padding(.vertical, 8)

            if !devicesCollapsed {
                // The synthetic Map device is always present, so
                // the empty-state path from before only fires in
                // the (impossible) case where displayedDevices
                // returns nothing. Just always render rows inline.
                //
                // We deliberately AVOID `List` here because List
                // inside a ScrollView refuses to expand to its
                // maxHeight — it collapses to a default size and
                // the user only sees Map + 1 iPhone even when 3
                // devices are connected. A plain ForEach renders
                // every row at its natural height; the outer
                // sidebar ScrollView handles overflow once the
                // combined sidebar content exceeds the window.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.displayedDevices) { device in
                        DeviceRow(device: device)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                state.selectedUDID == device.udid
                                ? Color.lociSage.opacity(0.18)
                                : Color.clear,
                                in: .rect(cornerRadius: 6)
                            )
                            .contentShape(.rect)
                            .onTapGesture {
                                state.selectedUDID = device.udid
                            }
                    }
                }
                .padding(.horizontal, 6)

                if state.devices.isEmpty {
                    Text("Plug an iPhone into USB and tap **Trust this computer** when prompted.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }

            // Section order, top → bottom (per user request):
            //
            //   Devices  → Bookmarks → Routes → Movement Modes →
            //   WiFi Devices → System Functions
            //
            // Bookmarks + Routes float to the top because they're
            // the most-used everyday surfaces. Movement Modes
            // follows since picking a mode is the typical next
            // step. WiFi Devices drops below — pairing / scanning
            // is rare day-to-day work. System Functions stays
            // last as the catch-all for one-time setup.

            BookmarksSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            RoutesSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            MovementModesSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            WiFiSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            SystemSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        }
        .frame(maxHeight: .infinity)

        // Fixed support/community footer. Sits OUTSIDE the ScrollView so
        // it stays glued to the sidebar bottom regardless of how much the
        // user scrolls or how many bookmarks they expand. By design, this
        // footer is compile-time only — no Settings toggle, no JSON, no
        // way to disable from the UI. See LICENSE "Brand & Support
        // Channels" carve-out for the policy reasoning.
        Divider()
        SidebarSupportFooter()
        }
        .frame(minWidth: 260)
        // Sheet attached at the sidebar root so it presents above the
        // whole UI, not inside a small device row. AppState owns the
        // `wifiConnectSheet` target; the sheet sets it back to nil to
        // dismiss.
        .sheet(item: Binding(
            get: { state.wifiConnectSheet },
            set: { state.wifiConnectSheet = $0 }
        )) { target in
            WiFiConnectSheet(target: target)
                .environment(state)
        }
        // Bookmark create / edit sheet — driven by either a pending
        // coord (from map right-click) or an existing bookmark
        // (from sidebar edit). The sheet's dismissAndClear() resets
        // both fields so the binding flips closed.
        .sheet(isPresented: Binding(
            get: { state.pendingBookmarkCoord != nil || state.editingBookmark != nil },
            set: { isOpen in
                if !isOpen {
                    state.pendingBookmarkCoord = nil
                    state.editingBookmark = nil
                }
            }
        )) {
            if let bm = state.editingBookmark {
                BookmarkEditSheet(coord: Coordinate(lat: bm.lat, lng: bm.lng),
                                  editing: bm)
                    .environment(state)
            } else if let coord = state.pendingBookmarkCoord {
                BookmarkEditSheet(coord: coord, editing: nil)
                    .environment(state)
            }
        }
        // Route create / edit sheet — driven by either a freshly
        // imported GPX (pendingRouteImport) or an existing record
        // (editingRoute). Same dismiss-clears-binding pattern as
        // BookmarkEditSheet.
        .sheet(isPresented: Binding(
            get: { state.pendingRouteImport != nil || state.editingRoute != nil },
            set: { isOpen in
                if !isOpen {
                    state.pendingRouteImport = nil
                    state.editingRoute = nil
                }
            }
        )) {
            if let r = state.editingRoute {
                RouteEditSheet(pending: nil, editing: r)
                    .environment(state)
            } else if let p = state.pendingRouteImport {
                RouteEditSheet(pending: p, editing: nil)
                    .environment(state)
            }
        }
        // v1.11.2 round 12: re-introduce RouteWaypointsEditSheet
        // via `.sheet(item:)` — SwiftUI handles this lazily (the
        // builder closure only fires when the optional flips
        // non-nil), so no per-body Binding rebuild like round 6's
        // `.sheet(isPresented:)` form. Item is `state.editingRouteWaypoints`
        // (Route is @Model and therefore Identifiable).
        .sheet(item: $state.editingRouteWaypoints) { route in
            RouteWaypointsEditSheet(route: route)
                .environment(state)
        }
    }

}

/// Pinned support / community footer that sits at the very bottom of
/// the sidebar — below System Functions, glued there regardless of how
/// far the user scrolls or how many bookmarks they expand. Two buttons:
/// Ko-fi (coral) for donation, LINE community (green) for chat.
///
/// **Policy note**: this footer is compile-time only. No Settings
/// toggle, no JSON, no `if` switch. That's intentional — the carve-out
/// in `LICENSE` ("Brand & Support Channels") reserves the author's
/// donation / contact channels outside the MIT grant, and removing
/// this footer in a fork requires editing the Swift source directly,
/// which forks should do *to substitute their own channels*, not to
/// strip the original's.
private struct SidebarSupportFooter: View {
    var body: some View {
        VStack(spacing: 8) {
            Link(destination: URL(string: "https://ych81.github.io/LociiGhost/sponsor.html")!) {
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer.fill")
                    Text("Buy me a bubble tea",
                         comment: "Sidebar footer — Ko-fi donation button, playful bubble-tea framing")
                        .lineLimit(1)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Color(red: 1.0, green: 0.369, blue: 0.357),
                    in: .rect(cornerRadius: 7)
                )
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Buy me a bubble tea"))

            Link(destination: URL(string: "https://line.me/ti/g2/-x9IldV0HMk-4Ydc-U93UnvOnUPbJ1En3z9XIg")!) {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                    Text("Join LINE community",
                         comment: "Sidebar footer — LINE community group link")
                        .lineLimit(1)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Color(red: 0.024, green: 0.780, blue: 0.333),
                    in: .rect(cornerRadius: 7)
                )
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Join LINE community"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}

/// Sidebar section for the M-style WiFi-only flow: a one-shot "Pair
/// for WiFi" that mints a fresh `~/.pymobiledevice3/remote_<UDID>.plist`
/// (USB cable required *only* for this single ritual), then a list of
/// LAN-discovered iPhones the user can Connect to without the cable.
private struct WiFiSection: View {
    @Environment(AppState.self) private var state
    /// Whole-section collapse — title row stays visible so the
    /// Refresh button doesn't disappear with the body.
    @State private var sectionCollapsed: Bool = false

    /// Any device in the sidebar list whose pair record is missing —
    /// determines whether the Pair button should be inviting or muted.
    private var hasUnpairedDevice: Bool {
        state.devices.contains { !$0.isWiFiPaired }
    }
    /// True if every device we know about is already WiFi-paired AND
    /// at least one such device exists. Used to render the button as
    /// "Already paired" instead of nudging the user to re-run.
    private var allPairedAlready: Bool {
        !state.devices.isEmpty && state.devices.allSatisfy { $0.isWiFiPaired }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wifi")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text("WiFi Devices")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Refresh stays visible even when the section is
                // collapsed so the user doesn't have to expand the
                // section just to re-scan the LAN.
                Button {
                    Task { await state.discoverWiFi() }
                } label: {
                    if state.isDiscoveringWiFi {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .padding(4)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(state.isDiscoveringWiFi)
                .hoverHighlight()
                .help(LocalizedStringKey("Scan LAN for paired iPhones"))
                Image(systemName: sectionCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                    .hoverHighlight(cornerRadius: 4, changesCursor: false)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            sectionCollapsed.toggle()
                        }
                    }
            }

            if !sectionCollapsed {
                bodyContent
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            pairButton

            // Two-stage progress indicator while the pair RPC is in
            // flight. Driven by `event.wifi_pair_progress` events the
            // daemon broadcasts at each handshake step.
            if let progress = state.pairProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text(progress.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            // Discovery results — empty state until user clicks
            // refresh OR pair-for-wifi (which auto-discovers on
            // success). nil distinguishes "haven't browsed yet" from
            // "browsed and found nothing".
            if let candidates = state.wifiCandidates {
                if candidates.isEmpty {
                    Text("No iPhones found on the LAN. Make sure the iPhone is on the same Wi-Fi and you've run **Pair for WiFi** once. You can also enter an IP manually below.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    ForEach(candidates) { c in
                        WiFiCandidateRow(candidate: c)
                    }
                }
            }

            // Manual IP entry — fallback for the case where mDNS
            // discovery missed the iPhone AND the /24 scan didn't
            // pick it up either (e.g. the iPhone is on a different
            // subnet but reachable via routed VPN).
            ManualIPEntry()
                .padding(.top, 6)
        }
    }

    /// Button label / state computed from sidebar's wifi_paired field
    /// and any in-flight pair operation. Three resting states:
    ///
    /// * No devices visible OR at least one unpaired → "Pair for WiFi"
    /// * Every visible device already has a remote pair record →
    ///   "Already paired · Re-pair…" (less prominent — clicking still
    ///   works for emergencies but it's no longer the primary CTA)
    /// * Pair RPC in flight → "Pairing…" with the live progress
    ///   message slot (the actual progress bar lives below)
    @ViewBuilder
    private var pairButton: some View {
        Button {
            Task { await state.pairForWiFi() }
        } label: {
            HStack(spacing: 8) {
                if state.isPairingForWiFi {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: allPairedAlready
                          ? "checkmark.seal.fill"
                          : "key.radiowaves.forward.fill")
                        .foregroundStyle(allPairedAlready ? Color.green : Color.lociSage)
                }
                VStack(alignment: .leading, spacing: 1) {
                    pairButtonTitleText
                        .font(.body)
                    pairButtonSubtitleText
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .opacity(allPairedAlready && !state.isPairingForWiFi ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(state.isPairingForWiFi)
    }

    /// Inline @ViewBuilder so each branch's `Text("literal")` is a real
    /// `LocalizedStringKey` and gets translated by the env locale.
    /// (The earlier `Text(stringFunction())` form passed a plain
    /// `String`, which SwiftUI shows verbatim — so the picker did
    /// nothing for these specific labels.)
    @ViewBuilder
    private var pairButtonTitleText: some View {
        if state.isPairingForWiFi {
            Text("Pairing…")
        } else if allPairedAlready {
            Text("Already paired · Re-pair…",
                 comment: "Pair-for-WiFi button title when pair record already exists")
        } else {
            Text("Pair for WiFi",
                 comment: "Sidebar button — runs the M-style RemotePairing setup ritual")
        }
    }

    @ViewBuilder
    private var pairButtonSubtitleText: some View {
        if state.isPairingForWiFi {
            // The progress message is a daemon-emitted English string
            // and doesn't pass through Localizable.strings — that's
            // intentional, since translating daemon output would mean
            // sending a locale param down the RPC and per-locale Python
            // strings. For Phase 5.1 the live progress message stays
            // English; the static fallback below honours the locale.
            if let progressMessage = state.pairProgress?.message {
                Text(verbatim: progressMessage)
            } else {
                Text("Tap Trust on iPhone when prompted.",
                     comment: "Pair button subtitle while RPC is in flight but no progress event yet")
            }
        } else if allPairedAlready {
            Text("Pair record on disk. Click only if WiFi connect stops working — generates a fresh record.",
                 comment: "Pair button subtitle when already paired")
        } else {
            Text("Plug iPhone in once. Two Trust prompts will appear; after that, WiFi works without the cable.",
                 comment: "Pair button subtitle for first-time pairing")
        }
    }
}

private struct WiFiCandidateRow: View {
    let candidate: WiFiCandidate
    @Environment(AppState.self) private var state

    /// Match precisely by (peer_ip, peer_port) so only THE row that
    /// originated the active session flips into "Connected" state.
    /// Fixed in v0.2.10 — earlier versions matched on
    /// "any network-connected device" which lit up every row when
    /// the user had multiple discovered candidates for the same
    /// iPhone (DHCP floating, multi-NIC, etc.).
    private var matchedSession: DeviceVM? {
        state.devices.first { dev in
            dev.connected
                && dev.transport == "network"
                && dev.peer_ip == candidate.ip
                && dev.peer_port == candidate.port
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .foregroundStyle(matchedSession != nil ? Color.green : Color.lociSage)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(matchedSession?.name ?? candidate.name)
                        .font(.callout)
                    if matchedSession != nil {
                        Text("Connected",
                             comment: "Capsule badge on a WiFi candidate row that's the active session")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green, in: .capsule)
                    }
                }
                Text("\(candidate.ip):\(candidate.port) · \(candidate.method)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let session = matchedSession {
                Button("Disconnect") {
                    Task { await state.disconnect(udid: session.udid) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if state.isConnectingWiFiByIP {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect") {
                    Task {
                        await state.connectWiFiByIP(
                            ip: candidate.ip, port: candidate.port
                        )
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Manual IP-and-port entry, for when neither mDNS nor the /24 TCP
/// scan picked the iPhone up — e.g. iPhone on a different subnet
/// reachable through routed VPN, or some unusual NAT layout. The
/// daemon's `wifi.connect_ip` accepts arbitrary `(ip, port)`; this
/// view just gives the user a way to feed that path without typing
/// JSON-RPC by hand.
/// Modal sheet shown when the user clicks "Connect via WiFi" from a
/// device row. Auto-discovers iPhones on the LAN, lists them as
/// click-to-connect rows, and falls back to a manual IP-entry form
/// when discovery returns nothing. Dismisses on a successful connect
/// or when the user cancels.
private struct WiFiConnectSheet: View {
    let target: WiFiConnectSheetTarget
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var manualIP: String = ""
    @State private var manualPort: String = "49152"
    @State private var didDiscover: Bool = false

    private var matchingDevice: DeviceVM? {
        state.devices.first(where: { $0.udid == target.udid })
    }
    private var isDiscovering: Bool { state.isDiscoveringWiFi }
    private var candidates: [WiFiCandidate] { state.wifiCandidates ?? [] }
    private var portInt: Int? {
        Int(manualPort.trimmingCharacters(in: .whitespaces))
    }
    private var ipIsPlausible: Bool {
        let parts = manualIP.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { (Int($0) ?? -1) >= 0 && (Int($0) ?? -1) <= 255 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "wifi")
                    .foregroundStyle(.tint)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect via WiFi")
                        .font(.headline)
                    if let dev = matchingDevice {
                        Text("Looking for \(dev.name) on the LAN…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await state.discoverWiFi() }
                } label: {
                    if isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isDiscovering)
                .help("Re-scan LAN")
            }

            Divider()

            // Body — three states: scanning / candidates / empty.
            Group {
                if isDiscovering && candidates.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Scanning LAN for paired iPhones…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Found \(candidates.count) device\(candidates.count == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(candidates) { c in
                            sheetCandidateRow(c)
                        }
                    }
                } else {
                    // didDiscover && empty: prompt for manual IP.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text("No iPhones found on the LAN.")
                                .font(.callout)
                        }
                        Text("Make sure the iPhone is on the same Wi-Fi and that you've already done **Pair for WiFi** for it once. If you know the IP, enter it below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Manual IP fallback — always available, but the prompt
            // text above only nudges towards it when discovery
            // returned nothing.
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Or enter IP manually")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("192.168.0.123", text: $manualIP)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    Text(":").foregroundStyle(.secondary)
                    TextField("49152", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 70)
                    Spacer(minLength: 4)
                    Button("Connect") {
                        guard let p = portInt else { return }
                        let ip = manualIP
                        Task {
                            await state.connectWiFiByIP(
                                ip: ip, port: p, udid: target.udid
                            )
                            await MainActor.run { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!ipIsPlausible || portInt == nil
                              || state.isConnectingWiFiByIP)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
        .task {
            // Auto-discover on first appearance. Subsequent re-opens
            // re-use the existing wifiCandidates (if any) — user can
            // tap the refresh button in the header to force-re-scan.
            if !didDiscover {
                didDiscover = true
                if state.wifiCandidates == nil
                    || (state.wifiCandidates?.isEmpty ?? true) {
                    await state.discoverWiFi()
                }
            }
        }
    }

    @ViewBuilder
    private func sheetCandidateRow(_ c: WiFiCandidate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                // v1.11.0: surface IP:port as the primary label. The
                // older title showed the mDNS instance name (a raw
                // UUID like `00DB4249-…-1412BA132751`) which means
                // nothing to the user; the IP is what they actually
                // need to match against the iPhone's Settings →
                // General → About → WiFi address. The `method` chip
                // hint (mdns / tcp_scan) stays as the secondary line
                // so the user knows how that row was discovered.
                Text("\(c.ip):\(c.port)")
                    .font(.callout.monospacedDigit())
                Text("via \(c.method)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isConnectingWiFiByIP {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect") {
                    let ip = c.ip
                    let port = c.port
                    Task {
                        await state.connectWiFiByIP(
                            ip: ip, port: port, udid: target.udid
                        )
                        await MainActor.run { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }
}

private struct ManualIPEntry: View {
    @Environment(AppState.self) private var state
    @State private var ip: String = ""
    @State private var port: String = "49152"

    private var ipIsPlausible: Bool {
        // Loose: 4 dot-separated digit groups, each 1-3 chars.
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            let n = Int($0) ?? -1
            return n >= 0 && n <= 255
        }
    }
    private var portInt: Int? {
        Int(port.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("192.168.0.123", text: $ip)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("49152", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 60)
                    Spacer(minLength: 4)
                    Button("Connect") {
                        guard let p = portInt else { return }
                        Task {
                            await state.connectWiFiByIP(ip: ip, port: p)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!ipIsPlausible || portInt == nil
                              || state.isConnectingWiFiByIP)
                }
                Text("Use when the iPhone isn't picked up by auto-discover (different subnet, VPN, etc.). Default port for RemotePairing is 49152.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } label: {
            Text("Manual IP entry")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Sidebar block below the device list. Houses things that aren't tied to
/// a specific device row but still belong to the device-management surface
/// — the most common one being "Enable Developer Mode" which the user may
/// want to trigger manually even when our auto-detection didn't flag it.
private struct SystemSection: View {
    @Environment(AppState.self) private var state
    @State private var showingDevModeSheet = false
    @State private var sectionCollapsed: Bool = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text("System Functions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: sectionCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .contentShape(.rect)
            .hoverHighlight(cornerRadius: 4, changesCursor: false)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sectionCollapsed.toggle()
                }
            }

            if !sectionCollapsed {
                Button {
                    showingDevModeSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "hammer.circle.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enable Developer Mode…")
                                .font(.body)
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6, changesCursor: false)
                .disabled(selectedDevice == nil)
                .sheet(isPresented: $showingDevModeSheet) {
                    if let dev = selectedDevice {
                        DeveloperModeSheet(device: dev)
                            .environment(state)
                    }
                }

                Button {
                    state.openPhoneControlSheet()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right.circle.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Phone Control…",
                                 comment: "Sidebar button — opens the LAN URL + PIN modal so a phone on the same WiFi can drive teleport / navigate / restore")
                                .font(.body)
                            Text("Drive LociiGhost from your phone over WiFi.",
                                 comment: "Subtitle for the Phone Control sidebar button")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6, changesCursor: false)
                .sheet(isPresented: $state.showPhoneControlSheet) {
                    PhoneControlSheet()
                        .environment(state)
                }

                // Sign-out-all-phones shortcut. Visible whenever
                // at least one phone session is alive — clicking
                // boots every paired tab in one go (calls the
                // same `phone.force_logout` RPC the lockout
                // overlay uses, just always-accessible).
                if state.phoneSessionActive {
                    Button(role: .destructive) {
                        Task { await state.forcePhoneLogout() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Sign out all phones",
                                     comment: "Sidebar shortcut — boots every authenticated phone tab")
                                    .font(.body)
                                Text("Kicks every paired phone and rotates the PIN.",
                                     comment: "Subtitle for the sign-out-all-phones sidebar button")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 6, changesCursor: false)
                }
            }
        }
    }

    private var selectedDevice: DeviceVM? {
        guard let udid = state.selectedUDID else { return nil }
        return state.devices.first(where: { $0.udid == udid })
    }

    private var subtitle: String {
        if let dev = selectedDevice {
            if dev.developer_mode == true {
                return "Already on for \(dev.name)."
            }
            return "Walk through enabling on \(dev.name)."
        }
        return "Select a device first."
    }
}

private struct DeviceRow: View {
    let device: DeviceVM
    @Environment(AppState.self) private var state
    @State private var showingDevModeSheet = false

    /// True when this row is the always-present Map device.
    /// Renders with a map glyph + a "browse-only" subtitle and no
    /// Connect / Disconnect button.
    private var isVirtualMap: Bool {
        device.udid == AppState.virtualMapUDID
    }

    var body: some View {
        if isVirtualMap {
            virtualMapBody
        } else {
            iphoneBody
        }
    }

    /// Bespoke compact row for the synthetic Map device. We don't
    /// re-use `iphoneBody` because most of its sub-views (iOS
    /// version, transport badges, dev-mode dot, Connect button)
    /// are meaningless here — rendering them would just be noise
    /// and forced-disabled clutter.
    private var virtualMapBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "map.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Map",
                         comment: "Sidebar entry name for the synthetic browse-only Map device")
                        .font(.body.weight(.medium))
                    Text("Browse-only",
                         comment: "Capsule badge on the synthetic Map device row")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.lociSage, in: .capsule)
                }
                Text("Look up locations without a connected iPhone.",
                     comment: "Subtitle on the synthetic Map device row")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
    }

    private var iphoneBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: device.isUSB ? "iphone" : "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(device.connected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isLikelyOffline {
                            // After health-check disconnects an
                            // unreachable WiFi device, the entry sticks
                            // around (we still have a pair record on
                            // disk, so it's NOT really gone — just not
                            // talking to us right now). Without an
                            // explicit "No active connection" tag the
                            // entry looks identical to a healthy
                            // disconnected device and the user can't
                            // tell why Connect immediately fails.
                            Text("No active connection",
                                 comment: "Capsule badge on a device row whose iPhone is offline")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.gray, in: .capsule)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("iOS \(device.iosVersion)")
                        Text("·")
                        transportBadges(for: device)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(devModeColor(for: device))
                            .frame(width: 6, height: 6)
                        Text(device.developerModeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                connectAction(for: device)
            }

            if device.developerModeNeedsAttention {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Developer Mode is off")
                        .font(.caption)
                    Button("Enable…") {
                        showingDevModeSheet = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingDevModeSheet) {
            DeveloperModeSheet(device: device)
                .environment(state)
        }
    }

    /// Heuristic: a device with a stored WiFi pair record but no
    /// active session and no transport other than "network" (i.e. not
    /// in usbmuxd right now) is almost certainly offline. The
    /// background health check at v0.2.10 also clears active sessions
    /// the moment the iPhone stops responding, which is what flips
    /// most rows into this state. We still let the user click Connect
    /// — we just stop pretending the connection is one button-press
    /// away from working.
    private var isLikelyOffline: Bool {
        guard !device.connected else { return false }
        // USB-discovered devices are never "offline" in this sense
        // — usbmuxd is reporting them right now, so a Connect should
        // succeed.
        if device.supportsUSB { return false }
        // The device exists in the list at all only because of the
        // wifi-paired path (pair record on disk). With nothing live,
        // we can't promise it's reachable.
        return device.isWiFiPaired
    }

    private func devModeColor(for device: DeviceVM) -> Color {
        switch device.developer_mode {
        case .some(true):  return .green
        case .some(false): return .orange
        case .none:        return .secondary
        }
    }

    /// Renders one capsule per transport usbmuxd currently sees for the
    /// device. The capsule for the *active* transport is filled in green
    /// when connected; idle transports stay neutral.
    @ViewBuilder
    private func transportBadges(for device: DeviceVM) -> some View {
        HStack(spacing: 3) {
            if device.supportsUSB {
                badgeChip(label: "USB",
                          highlight: device.connected && device.transport == "usb")
            }
            if device.supportsWiFi {
                badgeChip(label: "WiFi",
                          highlight: device.connected && device.transport == "network")
            }
            if !device.supportsUSB && !device.supportsWiFi {
                Text(device.transport.uppercased())
            }
        }
    }

    private func badgeChip(label: String, highlight: Bool) -> some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                highlight ? AnyShapeStyle(Color.green.opacity(0.22))
                          : AnyShapeStyle(Color.secondary.opacity(0.15)),
                in: .capsule
            )
            .foregroundStyle(highlight ? Color.green : Color.secondary)
    }

    /// Connect/Disconnect control. Becomes a menu when both USB and WiFi
    /// are available, so the user can pick the transport explicitly
    /// without unplugging the USB cable. WiFi entries route through
    /// the WiFiConnectSheet (which auto-discovers and lets the user
    /// pick an IP) instead of the legacy Bonjour-only path that on
    /// iOS 26 returns a service-map-stripped RSD.
    @ViewBuilder
    private func connectAction(for device: DeviceVM) -> some View {
        if device.connected {
            Button("Disconnect") {
                Task { await state.disconnect(udid: device.udid) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } else {
            // Unified pull-down for every disconnected device,
            // regardless of which transports the row currently
            // supports. The default label is **"Connect via USB"**
            // because USB is the safer / more reliable bring-up
            // path — WiFi-only sessions need a fresh remote-pairing
            // dance that breaks the moment the iPhone reboots,
            // whereas USB Just Works for any iOS version we
            // care about.
            //
            // Items in the menu are always shown but disabled when
            // the corresponding transport isn't currently
            // available — better UX than hiding them and leaving
            // the user wondering whether the option exists.
            //
            //   * Connect via USB — disabled when usbmuxd doesn't
            //     currently see the device on USB (cable unplugged)
            //   * Connect via WiFi… — disabled when no WiFi pair
            //     record exists yet OR the transport list doesn't
            //     include "network"
            //   * Don't connect — pure dismiss; explicit
            //     "I'm just looking" exit instead of clicking
            //     outside the menu
            Menu {
                Button {
                    Task {
                        await state.connect(udid: device.udid, preferWiFi: false)
                    }
                } label: {
                    Label("Connect via USB",
                          systemImage: "cable.connector")
                }
                .disabled(!device.supportsUSB)
                .help(device.supportsUSB
                      ? LocalizedStringKey("Connect via USB cable")
                      : LocalizedStringKey("Plug in the USB cable first"))

                Button {
                    state.openWiFiConnectFlow(udid: device.udid)
                } label: {
                    Label("Connect via WiFi…",
                          systemImage: "wifi")
                }
                .disabled(!device.supportsWiFi)
                .help(device.supportsWiFi
                      ? LocalizedStringKey("Open the WiFi candidate picker")
                      : LocalizedStringKey("Run **Pair for WiFi** once with the cable plugged in"))

                Divider()

                Button(role: .cancel) {
                    // Pure dismiss — Menu already closes on
                    // selection so this body is intentionally
                    // empty.
                } label: {
                    Label("Don't connect",
                          systemImage: "xmark")
                }
            } label: {
                Text("Connect via USB")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .font(.caption)
        }
    }
}

private struct DaemonStatusPill: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // v1.11.2 round 4 perf revert: the conditional Button wrapper
        // (when daemonStatus == .failed) was a measurable contributor
        // to view-tree size growth that hurt overall layout perf.
        // The AppState auto-elevate trigger + the AdminPromptBanner
        // are still the recovery affordances; this is back to a
        // simple status display.
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("lociighostd: \(state.daemonStatus.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !state.daemonVersion.isEmpty {
                Text("v\(state.daemonVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var color: Color {
        switch state.daemonStatus {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }
}

private struct Overlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdminPromptBanner()
            if !state.pendingStops.isEmpty,
               let udid = state.selectedUDID {
                if state.navigationControlsHidden {
                    Button {
                        state.navigationControlsHidden = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.below.rectangle")
                            Text("\(state.pendingStops.count) stops — show controls",
                                 comment: "Floating chip shown when ControlPanel is minimised — click to bring it back")
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey("Reopen the route controls"))
                } else {
                    ControlPanel(udid: udid, onDismiss: {
                        state.navigationControlsHidden = true
                    })
                }
            }
            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .padding(8)
                    .background(.red.opacity(0.15), in: .rect(cornerRadius: 6))
                    .transition(.opacity)
                    // Auto-dismiss the error toast after ~10 s. v1.10.7
                    // hotfix: earlier behaviour was "set lastError once,
                    // sits forever" — so a preflight error ("Connect a
                    // device first.") stayed visible long after the user
                    // had actually connected. `.task(id: err)` restarts
                    // the timer whenever a new error arrives, and the
                    // `state.lastError == err` guard before clearing
                    // means a fresher error written mid-sleep isn't
                    // wiped.
                    .task(id: err) {
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled else { return }
                        if state.lastError == err { state.lastError = nil }
                    }
            }
            // Non-error informational toast. Tinted blue so it doesn't
            // get confused with the red error toast above. Auto-dismisses
            // after ~10 s via AppState.showInfo().
            if let info = state.lastInfo {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.caption)
                    Text(info)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(.blue.opacity(0.12), in: .rect(cornerRadius: 6))
            }
        }
        .onChange(of: state.pendingStops.isEmpty) { _, isEmpty in
            // Reset minimise state when stops drop to zero so the
            // next planning session shows the full ControlPanel by
            // default — the user shouldn't have to remember they
            // hid it during a previous trip.
            if isEmpty { state.navigationControlsHidden = false }
        }
    }
}
