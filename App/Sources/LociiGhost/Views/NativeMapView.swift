import SwiftUI
import MapKit
import CoreLocation
import SwiftData
import LociiGhostCore

/// SwiftUI-native map view used when the active `MapTileLayer` is one
/// of the Apple-rendered options. Sits behind the same `AppState`
/// surface as `MapContainerView` so the rest of the app (sidebar,
/// status bar, bottom bar, recent places, etc.) doesn't need to know
/// which renderer is in front.
///
/// Why two map views: SwiftUI's `Map` doesn't accept `MKTileOverlay`
/// (no raster-tile API yet), so the OSM / Carto / ESRI options have
/// to stay on the NSViewRepresentable-wrapped MKMapView. But for the
/// Apple layers — which the vast majority of users sit on — the
/// SwiftUI view bypasses the NSViewRepresentable bridging that
/// surfaced as user-perceived pan lag in the post-teleport state
/// (the bridging fired SwiftUI's layout / preference cascade per CA
/// display tick; the native view doesn't).
///
/// Phase A scope: simulated puck + Mac puck, pendingMapFly-driven
/// camera flight, debounced region-change save, left-click handler
/// (browse cursor / multi-stop staging). Route polyline, multi-stop
/// pins, destination flag, search preview, random-walk circle,
/// bookmark overlay, and the right-click NSMenu are deferred to
/// Phases B / C.
struct NativeMapView: View {
    @Environment(AppState.self) private var state
    /// All saved bookmarks. Used to render the optional indigo pin
    /// overlay when `state.showBookmarksOnMap` is true. SwiftData
    /// @Query is cheap when filtered/sorted at the storage layer;
    /// the array is observed and refetches on bookmark mutations.
    @Query(sort: [SortDescriptor(\Bookmark.createdAt, order: .reverse)])
    private var bookmarks: [Bookmark]
    /// SwiftUI Map's authoritative camera. `.automatic` until the
    /// `.onAppear` block seeds it from `savedMapCamera` or a sensible
    /// default — that branch only fires once, after which all camera
    /// changes flow through `applyFly(_:)` (programmatic, from
    /// `state.pendingMapFly`) or the user's own gestures.
    @State private var camera: MapCameraPosition = .automatic
    /// Selection drives the bookmark-tap → photo-sheet path. SwiftUI
    /// `Marker` is selectable via the Map's `selection:` binding;
    /// we react to changes by opening the bookmark image sheet and
    /// immediately deselecting so the next tap on the same pin fires
    /// again.
    @State private var selectedBookmarkID: PersistentIdentifier?
    /// Last `state.pendingMapFly.id` we serviced; ignore re-applies
    /// of the same request the way MapContainerView does.
    @State private var lastServicedFlyID: UUID?
    /// Debounce handle for the region-change save. Mirrors the
    /// `saveCameraTask` pattern in MapContainerView so back-to-back
    /// pans don't write to SwiftData on every pixel.
    @State private var saveCameraTask: Task<Void, Never>?
    /// Cached scanline polylines for the S2 grid overlay; rebuilt by
    /// `recomputeS2(region:)` after the camera has settled. Scanlines
    /// (one per i or j boundary) instead of per-cell polygons cut
    /// the render-side workload from O(cells) to O(√cells) which is
    /// what makes the layer usable at city zoom.
    @State private var s2Lines: [[CLLocationCoordinate2D]] = []
    /// Mutable scratch state held inside a class so writes don't
    /// invalidate the SwiftUI view's body — SwiftUI tracks @State
    /// references by identity, so mutating properties on a stored
    /// class instance is invisible to the diff. Used for the
    /// camera-region cache (consulted when a toggle / level picker
    /// change forces a recompute outside a camera-change callback).
    @State private var s2Holder = S2GridHolder()
    /// Smallest cell:viewport-height ratio we'll bother rendering at.
    /// 0.0005 ≈ 0.5 px on a typical 1 000 px-tall map area — leaves
    /// the grid visible from city-block detail right out to "all of
    /// Taiwan" zoom for coarse levels (L13 at 1.2 km cells covers
    /// the whole island within the scanline cap). Finer levels fall
    /// off naturally once their cells are sub-pixel.
    private static let s2SuppressionRatio: Double = 0.0005
    /// Max horizontal + vertical scanlines we'll hand to MapKit.
    /// At 2 000 polylines the `MapPolyline` ForEach still rebuilds
    /// in well under a frame; beyond that the grid would be denser
    /// than the screen has pixels to draw it anyway.
    private static let s2ScanlineCap = 2_000

    var body: some View {
        MapReader { proxy in
            Map(position: $camera,
                interactionModes: .all,
                selection: $selectedBookmarkID,
            ) {
                annotations
            }
            .mapStyle(currentMapStyle)
            .onMapCameraChange(frequency: .onEnd) { context in
                scheduleSave(region: context.region)
                // The S2 grid piggybacks on the camera-end notification
                // rather than `.continuous` — `.onEnd` fires once when
                // the user lets go of the pan / scroll-zoom, exactly
                // when we want to recompute. `.continuous` fired at
                // 60 Hz and the resulting @State writes invalidated
                // body each tick.
                s2Holder.lastObservedRegion = context.region
                recomputeS2(region: context.region)
            }
            .onChange(of: state.showS2GridOnMap) { _, _ in
                recomputeFromCachedRegion()
            }
            .onChange(of: state.s2GridLevel) { _, _ in
                recomputeFromCachedRegion()
            }
            .onChange(of: state.pendingMapFly) { _, new in
                guard let new, new.id != lastServicedFlyID else { return }
                lastServicedFlyID = new.id
                applyFly(new)
            }
            .onChange(of: selectedBookmarkID) { _, new in
                // Open the photo sheet on bookmark-pin tap. Clear
                // immediately so re-tapping the same pin re-opens
                // (without this the second tap would be a no-op).
                guard let id = new,
                      let bm = bookmarks.first(where: { $0.persistentModelID == id })
                else { return }
                state.mapPreviewingBookmark = bm
                selectedBookmarkID = nil
            }
            .onTapGesture { screenPoint in
                guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                handleTap(coord: coord)
            }
            // Right-click NSMenu — SwiftUI's `.contextMenu` doesn't
            // give us the click location and SwiftUI Map's tap gesture
            // only fires for primary clicks. An overlaid NSView with
            // an event-type-aware hitTest lets primary clicks pass
            // straight through to the underlying SwiftUI Map while
            // capturing secondary clicks. The catcher pops the menu
            // itself at its own local point — popping from a parent
            // view's coordinate space miscalculated the screen
            // position by the inset of the navigation split / window
            // chrome, landing the menu far from the cursor.
            .overlay {
                RightClickCatcher { localPoint -> NSMenu? in
                    guard let coord = proxy.convert(localPoint, from: .local) else { return nil }
                    return buildContextMenu(coord: coord)
                }
            }
            .onAppear { seedInitialCamera() }
        }
    }

    // MARK: - Annotations

    @MapContentBuilder
    private var annotations: some MapContent {
        // ── Preview polyline (faded) ────────────────────────────────
        // Drawn while the user is staging multi-stop / nav before
        // hitting Navigate. Always layered first so the active route
        // and pins draw on top.
        if !state.previewRoute.isEmpty {
            MapPolyline(coordinates: state.previewRoute.map { $0.cl })
                .stroke(
                    (state.previewIsStraightLine ? Color.teal : Color.orange).opacity(0.55),
                    style: StrokeStyle(
                        lineWidth: 4,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: state.previewIsStraightLine ? [6, 4] : [],
                    ),
                )
        }
        // ── Active route polyline ───────────────────────────────────
        if let route = state.activeRoute, !route.isEmpty {
            MapPolyline(coordinates: route.map { $0.cl })
                .stroke(
                    (state.activeRouteIsStraightLine ? Color.teal : Color.orange).opacity(0.95),
                    style: StrokeStyle(
                        lineWidth: 5,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: state.activeRouteIsStraightLine ? [10, 6] : [],
                    ),
                )
        }
        // ── Random walk bounded centre disc ─────────────────────────
        // Prefers the LIVE walker's own centre + radius so the disc
        // stays anchored at the spot where the user pressed Start,
        // even after we've switched away from this iPhone and back
        // (v1.13.1: pre-fix, the disc drifted onto the live position
        // because RandomWalkPanel kept resetting `randomWalkPreview…`
        // to `simulatedLocation`). Falls back to the preview values
        // while the panel is open but the walker hasn't started yet.
        if let center = state.randomWalk?.center ?? state.randomWalkPreviewCenter,
           let radius = state.randomWalk?.radiusM ?? state.randomWalkPreviewRadiusM {
            MapCircle(center: center.cl, radius: radius)
                .foregroundStyle(Color.purple.opacity(0.12))
                .stroke(
                    Color.purple.opacity(0.7),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4]),
                )
        }
        // ── Random walk planned path (during walking) ───────────────
        if let rw = state.randomWalk, !rw.plannedPath.isEmpty {
            MapPolyline(coordinates: rw.plannedPath.map { $0.cl })
                .stroke(
                    Color.purple.opacity(0.85),
                    style: StrokeStyle(lineWidth: 3, dash: [4, 4]),
                )
        }
        // ── Staging stops (red, numbered) ───────────────────────────
        // Only when not currently navigating; once Navigate fires
        // these get promoted into activeWaypoints (blue) and the
        // staging copies clear.
        if !state.navigationActive {
            ForEach(Array(state.pendingStops.enumerated()), id: \.offset) { idx, stop in
                Annotation(
                    "Stop \(idx + 1)",
                    coordinate: stop.cl,
                ) {
                    stopBadge(number: idx + 1, color: .red)
                }
            }
        }
        // ── Live waypoints (blue, numbered) ─────────────────────────
        ForEach(Array(state.activeWaypoints.enumerated()), id: \.offset) { idx, wp in
            Annotation(
                "Waypoint \(idx + 1)",
                coordinate: wp.cl,
            ) {
                stopBadge(number: idx + 1, color: .blue)
            }
        }
        // ── Destination flag (active multi-stop / nav end) ──────────
        if let dest = state.activeDestination {
            Annotation(
                "Destination",
                coordinate: dest.cl,
            ) {
                flagBadge(color: .purple, glyph: "flag.checkered")
            }
        }
        // ── Search preview marker ───────────────────────────────────
        if let search = state.searchPreviewCoord {
            Annotation(
                "Preview",
                coordinate: search.cl,
            ) {
                flagBadge(color: .orange, glyph: "magnifyingglass")
            }
        }
        // ── Simulated / browse puck ─────────────────────────────────
        if let focus = state.currentMapFocus {
            Annotation(
                simulatedTitle,
                coordinate: focus.cl,
            ) {
                simulatedPuck
            }
            .annotationTitles(.visible)
        }
        // ── Mac proxy pin ───────────────────────────────────────────
        // Hidden whenever a simulated / browse pin already shows so
        // we don't render two "you are here" dots.
        if state.currentMapFocus == nil,
           let mac = state.macLocation.coordinate {
            Annotation(
                "Mac location (≈ iPhone real GPS)",
                coordinate: mac,
            ) {
                macPuck
            }
        }
        // ── S2 grid overlay ─────────────────────────────────────────
        // One `MapPolyline` per grid scanline (horizontal or vertical),
        // not per cell — a typical level-17 city viewport that needed
        // ~4 000 polygons now needs ~130 polylines. The MapContent
        // diff at 60 Hz body re-evals (every state.* touch) was the
        // main bottleneck of the per-polygon version.
        if state.showS2GridOnMap {
            let weight = state.s2GridLevel >= 18 ? 0.6
                       : state.s2GridLevel >= 16 ? 0.8
                       : 1.1
            ForEach(Array(s2Lines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(Color.indigo.opacity(0.6), lineWidth: weight)
            }
        }
        // ── Bookmark overlay ────────────────────────────────────────
        // Using Marker (not Annotation) for two reasons:
        //   * SwiftUI Map auto-clusters Markers at low zoom levels,
        //     which is essential when the overlay has 3 000+ entries.
        //   * Marker integrates with the Map's `selection:` binding,
        //     so a tap drives `selectedBookmarkID` → photo sheet
        //     without a separate gesture stack.
        if state.showBookmarksOnMap {
            ForEach(bookmarks) { bm in
                Marker(
                    bm.name,
                    systemImage: "bookmark.fill",
                    coordinate: CLLocationCoordinate2D(latitude: bm.lat, longitude: bm.lng),
                )
                .tint(.indigo)
                .tag(bm.persistentModelID)
            }
        }
    }

    /// Numbered stop badge — red for staging, blue for live waypoints.
    /// Matches the visual contract MKMarkerAnnotationView used in
    /// MapContainerView (marker shape + colour + integer glyph).
    private func stopBadge(number: Int, color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    /// Square marker with an SF Symbol glyph centred inside — used
    /// for the destination flag and the search-preview pin.
    private func flagBadge(color: Color, glyph: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white, lineWidth: 1.5),
                )
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var simulatedTitle: String {
        state.isVirtualMapSelected
            ? String(localized: "You",
                     comment: "Native map puck label in browse-only Map mode — \"you are here\"")
            : "iPhone (simulated)"
    }

    private var simulatedPuck: some View {
        ZStack {
            Circle()
                .fill((state.isVirtualMapSelected ? Color.blue : Color.green)
                      .opacity(0.25))
                .frame(width: 28, height: 28)
            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
            Circle()
                .fill(state.isVirtualMapSelected ? Color.blue : Color.green)
                .frame(width: 16, height: 16)
            Image(systemName: state.isVirtualMapSelected ? "person.fill" : "iphone")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var macPuck: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 22, height: 22)
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
            Circle()
                .fill(Color.blue)
                .frame(width: 11, height: 11)
        }
    }

    // MARK: - Map style

    private var currentMapStyle: MapStyle {
        switch state.mapTileLayer {
        case .appleSatellite: return .imagery
        // Raster layers (openStreetMap, cartoVoyager, esriSatellite) are
        // handled by MapContainerView, not this view; default-fall
        // through to Standard so we never crash if dispatcher gets it
        // wrong.
        case .appleStandard, .openStreetMap, .cartoVoyager, .esriSatellite:
            return .standard
        }
    }

    // MARK: - Initial camera

    private func seedInitialCamera() {
        if state.isVirtualMapSelected {
            // Virtual map always opens at Taipei (matches
            // MapContainerView's makeNSView contract — power users
            // dragging across continents shouldn't have the next
            // browse session land on the wrong side of the planet).
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
                latitudinalMeters: 4_000,
                longitudinalMeters: 4_000,
            ))
        } else if let saved = state.savedMapCamera {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: saved.center.lat,
                                               longitude: saved.center.lng),
                latitudinalMeters: saved.spanMeters * 2,
                longitudinalMeters: saved.spanMeters * 2,
            ))
        } else {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
                latitudinalMeters: 4_000,
                longitudinalMeters: 4_000,
            ))
        }
    }

    // MARK: - pendingMapFly handling

    private func applyFly(_ req: MapFlyRequest) {
        let center = CLLocationCoordinate2D(latitude: req.coordinate.lat,
                                            longitude: req.coordinate.lng)
        // preserveZoom = follow-puck path; mirror MapContainerView's
        // "shift the centre, keep the zoom" semantics by using a
        // .camera with the same distance. SwiftUI Map's animation is
        // already smooth for these per-tick updates so we don't need
        // the explicit animated:false dance.
        if req.preserveZoom {
            withAnimation(.linear(duration: 0.12)) {
                camera = .camera(MapCamera(
                    centerCoordinate: center,
                    distance: currentCameraDistance(),
                    heading: 0,
                    pitch: 0,
                ))
            }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                camera = .region(MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: req.spanMeters,
                    longitudinalMeters: req.spanMeters,
                ))
            }
        }
    }

    /// Best-effort current camera distance for the preserveZoom path.
    /// SwiftUI's `MapCameraPosition` doesn't expose a "current" getter
    /// before .onMapCameraChange has fired at least once, so we keep
    /// the last known distance in a stored @State for the next fly.
    @State private var lastCameraDistance: CLLocationDistance = 4_000
    private func currentCameraDistance() -> CLLocationDistance { lastCameraDistance }

    // MARK: - Region-change save

    private func scheduleSave(region: MKCoordinateRegion) {
        // Remember the distance / span so a follow-puck fly that
        // immediately follows can preserve the user's zoom.
        let spanMeters = region.span.latitudeDelta * 111_000
        lastCameraDistance = max(500, spanMeters)

        saveCameraTask?.cancel()
        let snapshotCenter = region.center
        let snapshotSpan = spanMeters
        saveCameraTask = Task { @MainActor [state] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            state.saveMapCamera(
                centerLat: snapshotCenter.latitude,
                centerLng: snapshotCenter.longitude,
                spanMeters: snapshotSpan / 2,
            )
        }
    }

    // MARK: - S2 grid

    /// Called by state observers (toggle, level picker) — recomputes
    /// against the most recently observed camera region. Falls back
    /// to clearing lines when nothing has been observed yet.
    private func recomputeFromCachedRegion() {
        if let region = s2Holder.lastObservedRegion {
            recomputeS2(region: region)
        } else if !state.showS2GridOnMap {
            if !s2Lines.isEmpty { s2Lines = [] }
        }
    }

    private func recomputeS2(region: MKCoordinateRegion) {
        guard state.showS2GridOnMap else {
            if !s2Lines.isEmpty { s2Lines = [] }
            return
        }
        let level = state.s2GridLevel
        let lat = region.center.latitude
        let cellMeters = S2Grid.approxCellSizeMeters(level: level, lat: lat)
        let viewportSpanMeters = region.span.latitudeDelta * 111_000.0
        // Zoom suppression: when each cell would barely register as a
        // few pixels the visualization is more noise than signal.
        if cellMeters / max(viewportSpanMeters, 1) < Self.s2SuppressionRatio {
            if !s2Lines.isEmpty { s2Lines = [] }
            return
        }
        let viewport = ViewportBounds(
            minLat: lat - region.span.latitudeDelta / 2,
            maxLat: lat + region.span.latitudeDelta / 2,
            minLng: region.center.longitude - region.span.longitudeDelta / 2,
            maxLng: region.center.longitude + region.span.longitudeDelta / 2,
        )
        let result = S2GridEnumerator.gridLines(
            viewport: viewport,
            level: level,
            scanlineCap: Self.s2ScanlineCap,
        )
        s2Lines = result.lines
        // Surface auto-coarsen state on AppState so the popover can
        // render a "zoom in to see L17" hint without recomputing the
        // gridLines a second time.
        state.s2EffectiveLevel = result.effectiveLevel
    }

    // MARK: - Tap handling

    private func handleTap(coord: CLLocationCoordinate2D) {
        let c = Coordinate(lat: coord.latitude, lng: coord.longitude)
        if state.isVirtualMapSelected {
            // Browse-only mode: clicking sets the "you are here"
            // cursor that the chips + recenter button read.
            // Mirrors MapContainerView's handleClick browse branch.
            state.browseCursor = c
            return
        }
        // Left-click stop-adding: only when Multi-stop mode is the
        // active panel AND no navigation is running. Same rule as
        // the imperative map's handleClick.
        guard state.activeMovementMode == .multiStop,
              !state.navigationActive
        else { return }
        state.appendQueueStop(c)
    }

    // MARK: - Right-click context menu

    /// Build (but don't pop) the context menu for the given coord.
    /// RightClickCatcher pops the returned menu at its own local
    /// click point, which keeps the menu anchored to the cursor.
    private func buildContextMenu(coord: CLLocationCoordinate2D) -> NSMenu {
        let menu = NSMenu()

        // Coord header — disabled, reads as info not action.
        let header = NSMenuItem()
        header.title = String(format: "📍  %.5f, %.5f", coord.latitude, coord.longitude)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let isConnected = state.devices
            .first(where: { $0.udid == state.selectedUDID })?
            .connected ?? false

        // Teleport
        let teleport = NSMenuItem(
            title: menuString("Teleport here"),
            action: nil,
            keyEquivalent: "",
        )
        teleport.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        teleport.isEnabled = isConnected
        if !isConnected {
            teleport.toolTip = menuString("Connect a device first.")
        } else {
            teleport.target = NativeMapMenuTarget.shared
            teleport.action = #selector(NativeMapMenuTarget.menuTeleport(_:))
            teleport.representedObject = NativeMapMenuAction.teleport(coord: coord, state: state)
        }
        menu.addItem(teleport)

        // Add as stop (only in Multi-stop mode)
        let canAddStop = state.activeMovementMode == .multiStop
        let addStop = NSMenuItem(
            title: menuString("Add as stop"),
            action: nil,
            keyEquivalent: "",
        )
        addStop.image = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: nil)
        addStop.isEnabled = canAddStop
        if !canAddStop {
            addStop.toolTip = menuString("Switch to Multi-stop mode first")
        } else {
            addStop.target = NativeMapMenuTarget.shared
            addStop.action = #selector(NativeMapMenuTarget.menuAddStop(_:))
            addStop.representedObject = NativeMapMenuAction.addStop(coord: coord, state: state)
        }
        menu.addItem(addStop)

        // Copy coordinates
        let copy = NSMenuItem(
            title: menuString("Copy coordinates"),
            action: #selector(NativeMapMenuTarget.menuCopyCoord(_:)),
            keyEquivalent: "",
        )
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.target = NativeMapMenuTarget.shared
        copy.representedObject = NativeMapMenuAction.copyCoord(coord: coord)
        menu.addItem(copy)

        menu.addItem(.separator())

        // Save as bookmark
        let bookmark = NSMenuItem(
            title: menuString("Save as bookmark…"),
            action: #selector(NativeMapMenuTarget.menuAddBookmark(_:)),
            keyEquivalent: "",
        )
        bookmark.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        bookmark.target = NativeMapMenuTarget.shared
        bookmark.representedObject = NativeMapMenuAction.bookmark(coord: coord, state: state)
        menu.addItem(bookmark)

        return menu
    }

    /// Localized lookup that honours the AppleLanguages override
    /// (same logic as MapContainerView's `menuString` helper).
    private func menuString(_ key: String) -> String {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let target: String
        switch lang {
        case "en":      target = "en"
        case "zh-Hant": target = "zh-Hant"
        default:        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        if let path = Bundle.main.path(forResource: target, ofType: "lproj"),
           let lprojBundle = Bundle(path: path) {
            return lprojBundle.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - Right-click event catcher

/// NSView that's transparent to primary clicks but captures secondary
/// clicks so we can pop a custom NSMenu. The trick is `hitTest` —
/// we return `self` only when the in-flight NSEvent is a right-down,
/// otherwise return `nil` to let the SwiftUI Map below receive
/// regular drags and taps.
private struct RightClickCatcher: NSViewRepresentable {
    /// Returns the menu to pop at the click point, or nil if the
    /// click should be ignored (e.g. coord conversion failed).
    let buildMenu: (CGPoint) -> NSMenu?

    func makeNSView(context: Context) -> NSView {
        let v = HitOnlyOnRightClickView()
        v.buildMenu = buildMenu
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HitOnlyOnRightClickView)?.buildMenu = buildMenu
    }
}

private final class HitOnlyOnRightClickView: NSView {
    var buildMenu: ((CGPoint) -> NSMenu?)?

    /// SwiftUI is top-left-origin; AppKit defaults to bottom-left.
    /// Without flipping, `convert(event.locationInWindow, from: nil)`
    /// returns a Y value measured up from the view's bottom, so the
    /// coord we hand to MapReader's `proxy.convert(_, from: .local)`
    /// would be vertically mirrored — clicks land at the wrong map
    /// coordinate and the dropped stop appears far from the cursor.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept right-click events; everything else (left
        // click, drag, scroll) falls through to the SwiftUI Map below.
        if NSApp.currentEvent?.type == .rightMouseDown {
            return self
        }
        return nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let menu = buildMenu?(p) else { return }
        // Pop in this view's own coord space so the menu anchors to
        // the cursor regardless of where this view sits inside the
        // window's split / chrome hierarchy.
        menu.popUp(positioning: nil, at: p, in: self)
    }
}

// MARK: - NSMenu action target

/// NSMenu item targets must be NSObject and live as long as the menu —
/// SwiftUI views don't qualify (struct-typed, recreated per body
/// eval). Use a process-wide singleton with `representedObject`
/// carrying the per-click payload. @MainActor-isolated since
/// NSMenu callbacks always fire on the main thread and we need to
/// touch AppState.
@MainActor
private final class NativeMapMenuTarget: NSObject {
    static let shared = NativeMapMenuTarget()

    @objc func menuTeleport(_ sender: NSMenuItem) {
        guard case let .teleport(coord, state) = sender.representedObject as? NativeMapMenuAction else { return }
        guard let udid = state.selectedUDID else { return }
        Task { await state.teleport(udid: udid, lat: coord.latitude, lng: coord.longitude) }
    }

    @objc func menuAddStop(_ sender: NSMenuItem) {
        guard case let .addStop(coord, state) = sender.representedObject as? NativeMapMenuAction else { return }
        state.appendQueueStop(Coordinate(lat: coord.latitude, lng: coord.longitude))
    }

    @objc func menuCopyCoord(_ sender: NSMenuItem) {
        guard case let .copyCoord(coord) = sender.representedObject as? NativeMapMenuAction else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(String(format: "%.6f, %.6f", coord.latitude, coord.longitude),
                     forType: .string)
    }

    @objc func menuAddBookmark(_ sender: NSMenuItem) {
        guard case let .bookmark(coord, state) = sender.representedObject as? NativeMapMenuAction else { return }
        state.pendingBookmarkCoord = Coordinate(lat: coord.latitude, lng: coord.longitude)
    }
}

@MainActor
private enum NativeMapMenuAction {
    case teleport(coord: CLLocationCoordinate2D, state: AppState)
    case addStop(coord: CLLocationCoordinate2D, state: AppState)
    case copyCoord(coord: CLLocationCoordinate2D)
    case bookmark(coord: CLLocationCoordinate2D, state: AppState)
}

private extension Coordinate {
    /// `CLLocationCoordinate2D` shorthand for MapContent builders.
    var cl: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// Mutable scratch the SwiftUI view needs but doesn't want SwiftUI
/// tracking — see `NativeMapView.s2Holder`. SwiftUI tracks `@State`
/// references by identity, so mutating a class instance's stored
/// properties is invisible to the diff and doesn't invalidate body
/// on every camera-change tick.
@MainActor
fileprivate final class S2GridHolder {
    var lastObservedRegion: MKCoordinateRegion?

    init() {}
}
