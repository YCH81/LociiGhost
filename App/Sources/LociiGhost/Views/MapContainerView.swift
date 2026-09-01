import SwiftUI
import MapKit
import CoreLocation
import Observation
import SwiftData
import LociiGhostCore

/// SwiftUI host for an MKMapView with three logical layers:
///
/// 1. **OpenStreetMap raster tiles** as the base map.
/// 2. **Annotations**:
///    - The Mac's CoreLocation reading, drawn as a translucent blue puck.
///      Apple does not let us read the iPhone's real GPS over DVT, so this
///      stands in as the user's true position whenever no simulation is
///      active. Labelled clearly so nobody mistakes it for the iPhone.
///    - The current simulated location (where the iPhone *thinks* it is
///      after a teleport), drawn as a green pin.
///    - The pending teleport target (where the user clicked but hasn't
///      committed), drawn as a red pin.
/// 3. **Click-to-coordinate**: a single click anywhere drops a pending
///    target. Apple's gesture recogniser cooperates with the map's own
///    pan/zoom because we set delaysPrimaryMouseButtonEvents = false.
struct MapContainerView: NSViewRepresentable {
    @Environment(AppState.self) private var state

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsScale = true
        map.isRotateEnabled = false
        // v1.11.2 round 21: reduce MapKit's per-frame render demand.
        // Tahoe's VectorKit pipeline runs onRenderTimerFired at ~60 Hz
        // (display refresh) regardless of state changes; the cheaper
        // the per-frame content, the less main-thread time MapKit
        // takes and the more headroom available for drag handling.
        //
        // - pitchEnabled false: disables 3D camera tilt, which the app
        //   never uses but otherwise costs perspective transform work
        //   every frame.
        // - showsBuildings false: 3D building extrusions are pure
        //   render cost we don't display.
        // - showsTraffic false: real-time traffic overlay polls + draws
        //   coloured road overlays we never reference.
        // - selectableMapFeatures = []: turns off POI tap hit-testing,
        //   which Apple keeps "live" each frame for pointer chasing.
        // - preferredConfiguration with flat elevation + muted style:
        //   trades visual richness for the cheapest standard render
        //   path. Roads + labels stay legible; 3D shading is dropped.
        map.isPitchEnabled = false
        map.showsBuildings = false
        map.showsTraffic = false
        if #available(macOS 13.0, *) {
            let config = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .muted,
            )
            config.showsTraffic = false
            map.preferredConfiguration = config
        }
        // Initial map region:
        //
        //   * Browse-only Map device selected → ALWAYS open at
        //     Taipei. A power user might have last panned to
        //     Tokyo while debugging an iPhone session; we don't
        //     want the next "open the app cold to look up an
        //     address" to silently land them on the other side
        //     of the East China Sea. Taipei is the home base
        //     for this app's primary user.
        //   * Real iPhone selected → restore the user's last
        //     visible region from SwiftData so the map opens
        //     where they left it (mid-trip continuation, etc.).
        //     Fall back to Taipei when there is no saved camera
        //     (first launch with an iPhone connected).
        if state.isVirtualMapSelected {
            map.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
                latitudinalMeters: 4_000,
                longitudinalMeters: 4_000
            )
        } else if let saved = state.savedMapCamera {
            map.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: saved.center.lat, longitude: saved.center.lng
                ),
                latitudinalMeters: saved.spanMeters * 2,
                longitudinalMeters: saved.spanMeters * 2
            )
        } else {
            map.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
                latitudinalMeters: 4_000,
                longitudinalMeters: 4_000
            )
        }

        // Initial base layer is whatever the user (or default) has
        // set on AppState. Subsequent changes are picked up by
        // updateNSView via the coordinator's `applyTileLayer`.
        Coordinator.applyTileLayer(state.mapTileLayer, to: map)

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.numberOfClicksRequired = 1
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)

        // Right-click brings up a small context menu so the user can
        // teleport / add a stop without first having to commit a left-
        // click pin and then walking through the side-panel buttons.
        let rightClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRightClick(_:))
        )
        rightClick.buttonMask = 0x2     // secondary (right) mouse button
        rightClick.numberOfClicksRequired = 1
        map.addGestureRecognizer(rightClick)

        context.coordinator.mapView = map
        // v1.11.2 round 20: kick off the coordinator's own observation
        // loop via `withObservationTracking`. From here on, state
        // changes flow directly to MapKit through the coordinator,
        // bypassing SwiftUI's view body re-eval entirely. The map
        // view is no longer dragged along when MainView /
        // BottomBar / etc redraw.
        context.coordinator.startObserving()

        // Warm-keep mechanism removed — empirically didn't address the
        // actual cause. Pure idle pan is already smooth; lag only
        // appears in the "iPhone connected + teleported" state, which
        // means the cause is something periodic that connection
        // introduces (daemon-emitted events from the simulated device's
        // CoreLocation echo, weather refresh tail, etc.), not a cold
        // VectorKit pipeline.

        return map
    }

    func updateNSView(_ nsView: MKMapView, context: Context) {
        // v1.11.2 round 20: no-op. The coordinator manages its own
        // state subscription via `withObservationTracking`. SwiftUI
        // may still call updateNSView for non-state reasons (layout,
        // window resize, etc.) — those don't need MapKit refreshes.
        // If the parent ever injects a different AppState reference,
        // re-bind and restart the observation loop.
        if context.coordinator.state !== state {
            context.coordinator.state = state
            context.coordinator.startObserving()
        }
    }

    /// Return the proposed size directly without consulting MKMapView's
    /// own intrinsicContentSize. MapKit recomputes its intrinsic size
    /// as its visible region changes (per-frame during pan), and
    /// SwiftUI's layout pass — which runs every CA display cycle while
    /// MKMapView is animating tiles — would otherwise re-query that
    /// per-frame, cascading a fresh sizeThatFits walk down the entire
    /// detail-pane tree (NavigationStackLayout → StackLayout → … →
    /// SizeFittingState). The pan-while-connected profile showed
    /// ~45 % of main-thread time in this cascade alone. We always want
    /// the map to fill whatever space the ZStack offers it; treating
    /// the proposed size as authoritative cuts the per-frame work and
    /// matches the visual contract we already enforce with the
    /// parent's `.frame(maxWidth: .infinity, maxHeight: .infinity)`.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: MKMapView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width,
               height: proposal.height ?? nsView.bounds.height)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var state: AppState
        weak var mapView: MKMapView?
        private var pendingStopAnnotations: [StopAnnotation] = []
        private var simulatedAnnotation: SimulatedAnnotation?
        private var macAnnotation: MacAnnotation?
        private var destinationAnnotation: DestinationAnnotation?
        private var searchPreviewAnnotation: SearchPreviewAnnotation?
        private var lastSearchPreviewSig: Coordinate?
        private var routePolyline: StyledPolyline?
        private var previewPolyline: StyledPolyline?
        private var randomWalkPreviewCircle: MKCircle?
        private var randomWalkPathPolyline: StyledPolyline?
        private var lastRWPathSignature: [Coordinate] = []
        private var lastRouteSignature: [Coordinate] = []
        private var lastRouteIsStraightLine: Bool = false
        private var lastPreviewSignature: [Coordinate] = []
        private var lastPreviewIsStraightLine: Bool = false
        private var lastRWPreviewSignature: (Coordinate, Double)?
        private var lastDestinationSignature: Coordinate?
        // v1.11.0 perf — three blocks below previously rebuilt their
        // pins on every `updateNSView` call (i.e. every 1 Hz position
        // event from the daemon). For a 274-stop route, that's ~550
        // MapKit add/remove operations per second on the main thread,
        // starving gestures and button events. With these signatures,
        // each block only rebuilds when its underlying state actually
        // changes.
        private var lastPendingStopsSig: [Coordinate] = []
        private var lastActiveWaypointsSig: [Coordinate] = []
        private var lastSimulatedSig: (Coordinate, Bool)?
        private var lastMacSig: (Coordinate, Double?)?
        private var didCenterOnMac = false
        private var lastServicedFlyID: UUID?
        /// Bookmark-pin cache. Key is the SwiftData persistent id so we
        /// can diff fetched results against the current map state
        /// without rebuilding from scratch every revision bump.
        private var bookmarkAnnotations: [PersistentIdentifier: BookmarkAnnotation] = [:]
        /// Last bookmarksRevision applied to the map; -1 forces the
        /// first sync after the overlay is enabled.
        private var lastBookmarksRevision: Int = -1
        /// Whether the bookmark overlay is currently painted. Used to
        /// detect transitions (off→on / on→off) so the sync function
        /// can skip the redundant fetch when nothing changed.
        private var lastBookmarksOverlayShown: Bool = false
        /// Active S2 grid scanline overlays. Wiped + rebuilt on every
        /// sync — the polyline count (≈ √cells) is small enough that
        /// a full rebuild is cheaper than a diff.
        private var s2GridOverlays: [S2GridPolyline] = []
        /// 100 ms debounce handle for `syncS2Grid` — fires from
        /// regionDidChange + observation ticks. Cancelled and rescheduled
        /// on every region change so a rapid pan only does one pass
        /// at the end.
        private var s2RecomputeTask: Task<Void, Never>?

        init(state: AppState) {
            self.state = state
        }

        // MARK: v1.11.2 round 20 — withObservationTracking loop

        /// Kicks off the standalone observation loop. From this point
        /// MapKit updates are driven by `withObservationTracking`,
        /// NOT by SwiftUI's view body re-evaluation. The map view is
        /// effectively decoupled from MainView's render cycle.
        func startObserving() {
            scheduleNextObservation()
            applyStateToMap()
        }

        /// Subscribe to one round of state mutations. The closure
        /// passed to `withObservationTracking` reads every state
        /// property whose change should trigger a MapKit refresh.
        /// `onChange` fires once on the next mutation of any of those
        /// properties, dispatches an apply pass, and re-subscribes
        /// so the loop continues.
        ///
        /// Note: properties read inside this closure form the
        /// subscription set. To avoid pulling in CoreLocation's
        /// 1 Hz publisher we ONLY read `state.macLocation.*` when
        /// `state.currentMapFocus == nil` (i.e. the Mac pin is
        /// actually going to render).
        private func scheduleNextObservation() {
            withObservationTracking { [self] in
                _ = state.activeRoute
                _ = state.activeRouteIsStraightLine
                _ = state.activeWaypoints
                _ = state.pendingStops
                _ = state.previewRoute
                _ = state.previewIsStraightLine
                _ = state.activeDestination
                _ = state.searchPreviewCoord
                _ = state.randomWalkPreviewCenter
                _ = state.randomWalkPreviewRadiusM
                _ = state.randomWalk
                _ = state.currentMapFocus
                _ = state.isVirtualMapSelected
                _ = state.pendingMapFly
                _ = state.mapTileLayer
                _ = state.showBookmarksOnMap
                _ = state.bookmarksRevision
                _ = state.showS2GridOnMap
                _ = state.s2GridLevel
                if state.currentMapFocus == nil {
                    _ = state.macLocation.coordinate
                }
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyStateToMap()
                    self.scheduleNextObservation()
                }
            }
        }

        /// Push the current state snapshot onto MKMapView. Same work
        /// updateNSView used to do — now triggered by the observation
        /// loop above instead of SwiftUI's per-body schedule.
        private func applyStateToMap() {
            guard let mv = mapView else { return }
            refreshAnnotations(on: mv)
            applyPendingFly(on: mv)
            Self.applyTileLayer(state.mapTileLayer, to: mv)
            syncBookmarkAnnotations(on: mv)
            scheduleS2GridSync(on: mv)
        }

        /// Reconcile `bookmarkAnnotations` with the SwiftData store and
        /// the user's overlay toggle. Three cases:
        ///
        ///   * Toggle OFF — strip every bookmark annotation, clear the
        ///     cache, exit.
        ///   * Toggle ON, no revision change since last sync, overlay
        ///     already shown — nothing to do.
        ///   * Toggle ON, otherwise — fetch the live bookmark list and
        ///     diff: insert new ones, remove deleted, update coords or
        ///     names on the survivors. Batched MapKit calls so 3000+
        ///     pins don't redraw one-by-one.
        private func syncBookmarkAnnotations(on map: MKMapView) {
            if !state.showBookmarksOnMap {
                if !bookmarkAnnotations.isEmpty {
                    map.removeAnnotations(Array(bookmarkAnnotations.values))
                    bookmarkAnnotations.removeAll(keepingCapacity: true)
                }
                lastBookmarksOverlayShown = false
                return
            }
            if lastBookmarksOverlayShown,
               lastBookmarksRevision == state.bookmarksRevision {
                return
            }
            lastBookmarksRevision = state.bookmarksRevision
            lastBookmarksOverlayShown = true

            // Fetch the live list. The state's modelContext is the same
            // one the sidebar's @Query sees, so we get the freshest
            // post-save snapshot.
            let fetched: [Bookmark] = {
                guard let ctx = state.bookmarkFetchContext else { return [] }
                return (try? ctx.fetch(FetchDescriptor<Bookmark>())) ?? []
            }()
            let fetchedIDs = Set(fetched.map(\.persistentModelID))

            var toRemove: [BookmarkAnnotation] = []
            for (id, ann) in bookmarkAnnotations where !fetchedIDs.contains(id) {
                toRemove.append(ann)
            }
            if !toRemove.isEmpty {
                map.removeAnnotations(toRemove)
                for ann in toRemove { bookmarkAnnotations[ann.persistentID] = nil }
            }

            var toAdd: [BookmarkAnnotation] = []
            for bm in fetched {
                if let existing = bookmarkAnnotations[bm.persistentModelID] {
                    // Keep the same annotation instance to preserve
                    // MapKit's view recycling — only push field updates.
                    if existing.coordinate.latitude != bm.lat ||
                       existing.coordinate.longitude != bm.lng {
                        existing.coordinate = CLLocationCoordinate2D(
                            latitude: bm.lat, longitude: bm.lng,
                        )
                    }
                    if existing.title != bm.name { existing.title = bm.name }
                    let subtitle = bm.category.isEmpty ? nil : bm.category
                    if existing.subtitle != subtitle { existing.subtitle = subtitle }
                    existing.hasImage = (bm.imageURL?.isEmpty == false)
                    let hex = state.categoryColorHex(bm.category)
                    if existing.colorHex != hex { existing.colorHex = hex }
                    let flower = FlowerPin.design(forStoredSymbol: bm.iconSymbol)?.id
                    if existing.flowerID != flower { existing.flowerID = flower }
                } else {
                    let ann = BookmarkAnnotation(
                        persistentID: bm.persistentModelID,
                        hasImage: bm.imageURL?.isEmpty == false,
                        colorHex: state.categoryColorHex(bm.category),
                        flowerID: FlowerPin.design(forStoredSymbol: bm.iconSymbol)?.id,
                    )
                    ann.coordinate = CLLocationCoordinate2D(
                        latitude: bm.lat, longitude: bm.lng,
                    )
                    ann.title = bm.name
                    ann.subtitle = bm.category.isEmpty ? nil : bm.category
                    bookmarkAnnotations[bm.persistentModelID] = ann
                    toAdd.append(ann)
                }
            }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }
        }

        // ── S2 grid overlay ─────────────────────────────────────────
        //
        // Driven by `state.showS2GridOnMap` / `state.s2GridLevel` +
        // the map's visible region. Recompute is debounced 100 ms via
        // `s2RecomputeTask` so a continuous pan only triggers one
        // BFS pass; in-between ticks the existing polygons stay on
        // screen (cheap to keep — MKMapView caches their renderers).

        /// Cell-side-to-viewport-height ratio below which the grid is
        /// hidden entirely. See the equivalent comment in
        /// NativeMapView for the threshold rationale.
        private static let s2SuppressionRatio: Double = 0.0005
        /// Scanline budget — matches the SwiftUI Map side. MKMapKit
        /// itself handles many more overlays, but `addOverlays` cost
        /// scales linearly with count.

        func scheduleS2GridSync(on map: MKMapView) {
            // Toggling off → wipe immediately, no debounce wait.
            if !state.showS2GridOnMap {
                if !s2GridOverlays.isEmpty {
                    map.removeOverlays(s2GridOverlays)
                    s2GridOverlays.removeAll(keepingCapacity: true)
                }
                s2RecomputeTask?.cancel()
                return
            }
            s2RecomputeTask?.cancel()
            s2RecomputeTask = Task { @MainActor [weak self, weak map] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let map else { return }
                self.syncS2Grid(on: map)
            }
        }

        private func syncS2Grid(on map: MKMapView) {
            guard state.showS2GridOnMap else { return }
            let region = map.region
            let level = state.s2GridLevel
            let lat = region.center.latitude
            let cellMeters = S2Grid.approxCellSizeMeters(level: level, lat: lat)
            let viewportSpanMeters = max(1, region.span.latitudeDelta * 111_000)
            if cellMeters / viewportSpanMeters < Self.s2SuppressionRatio {
                if !s2GridOverlays.isEmpty {
                    map.removeOverlays(s2GridOverlays)
                    s2GridOverlays.removeAll(keepingCapacity: true)
                }
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
                scanlineCap: MapGeometryPolicy.s2ScanlineCap,
            )
            state.s2EffectiveLevel = result.effectiveLevel

            // Whole-overlay rebuild — scanline count (~√cells) is
            // small enough that a diff isn't worth the bookkeeping.
            if !s2GridOverlays.isEmpty {
                map.removeOverlays(s2GridOverlays)
                s2GridOverlays.removeAll(keepingCapacity: true)
            }
            if result.lines.isEmpty { return }
            var toAdd: [S2GridPolyline] = []
            toAdd.reserveCapacity(result.lines.count)
            for coords in result.lines {
                let poly = S2GridPolyline(coordinates: coords, count: coords.count)
                poly.s2Level = level
                toAdd.append(poly)
            }
            s2GridOverlays = toAdd
            map.addOverlays(toAdd, level: .aboveRoads)
        }

        /// Last applied layer per MKMapView, keyed by ObjectIdentifier
        /// of the map. Static so makeNSView and updateNSView agree
        /// without storing per-instance state on the Coordinator
        /// (which would risk staleness across NSViewRepresentable
        /// re-creates). One-entry dictionary in the common case.
        private static var lastAppliedLayer: [ObjectIdentifier: MapTileLayer] = [:]

        /// Apply a base-layer choice to the map. Removes any previous
        /// tile overlay and either:
        ///
        ///   * sets `mapType` to .standard / .hybridFlyover for the
        ///     Apple-rendered cases, or
        ///   * adds a fresh MKTileOverlay for the raster cases.
        ///
        /// Idempotent — checks `lastAppliedLayer` first and bails
        /// when the user picked the same layer they already had.
        static func applyTileLayer(_ layer: MapTileLayer, to map: MKMapView) {
            let key = ObjectIdentifier(map)
            if lastAppliedLayer[key] == layer { return }
            lastAppliedLayer[key] = layer

            // Wipe any previous tile overlay; non-tile overlays
            // (route polyline, etc.) live in `addOverlay(_,level:)`
            // calls elsewhere and we do NOT want to wipe those.
            for ov in map.overlays where ov is MKTileOverlay {
                map.removeOverlay(ov)
            }

            if let template = layer.tileURLTemplate {
                let tile = MKTileOverlay(urlTemplate: template)
                tile.canReplaceMapContent = true
                map.addOverlay(tile, level: .aboveLabels)
                // For raster layers we still want MKMapType to be
                // standard so MapKit's labels don't double up on
                // top of the tile imagery.
                map.mapType = .standard
            } else {
                // Apple-rendered layers — no tile overlay; let MapKit
                // do its native vector / satellite render.
                switch layer {
                case .appleSatellite: map.mapType = .hybridFlyover
                case .appleStandard:  map.mapType = .standard
                default:              map.mapType = .standard
                }
            }
        }

        func applyPendingFly(on map: MKMapView) {
            guard let req = state.pendingMapFly, req.id != lastServicedFlyID else { return }
            lastServicedFlyID = req.id
            let center = CLLocationCoordinate2D(
                latitude: req.coordinate.lat,
                longitude: req.coordinate.lng,
            )
            let region: MKCoordinateRegion
            let animated: Bool
            if req.preserveZoom {
                // Follow-puck path: keep the user's current span,
                // only shift the centre. animated=false: the 1 Hz
                // animated pan was accumulating on macOS Tahoe.
                region = MKCoordinateRegion(center: center, span: map.region.span)
                animated = false
                // Gate the camera-save path: this setRegion is
                // programmatic (1 Hz follow tick), not a user pan.
                // MKMapView fires regionWillChange/regionDidChange
                // synchronously during setRegion on macOS, so the
                // flag fully covers the delegate callbacks.
                applyingProgrammaticFly = true
                map.setRegion(region, animated: animated)
                applyingProgrammaticFly = false
            } else {
                region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: req.spanMeters,
                    longitudinalMeters: req.spanMeters,
                )
                animated = true
                map.setRegion(region, animated: animated)
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            let coordinate = Coordinate(
                lat: coord.latitude,
                lng: coord.longitude,
            )
            if state.isVirtualMapSelected {
                // Browse-only mode: clicking the map sets the
                // "what am I looking at" pin (via `browseCursor`,
                // a transient field that's INDEPENDENT of
                // `simulatedLocation`). That way:
                //
                //   * Status-bar chips populate for the clicked
                //     spot (via `currentMapFocus`)
                //   * Persistence + real-iPhone code paths stay
                //     untouched — connecting an iPhone right after
                //     a browse session no longer inherits the
                //     browse pin's location as the iPhone's
                //     "simulated GPS"
                state.browseCursor = coordinate
                refreshAnnotations(on: map)
                return
            }
            // Left-click stop-adding: only when Multi-stop mode is the
            // active panel AND no navigation is running. Once a trip
            // is in flight, left-click is disabled to prevent accidental
            // stops — use the right-click context menu to inject stops
            // mid-trip (right-click "Add as stop" is not restricted).
            guard state.activeMovementMode == .multiStop,
                  !state.navigationActive else { return }
            // Append rather than replace so successive clicks build a
            // multi-stop trip. In dwell mode this also injects the new
            // coord into dwellContext.remainingStops so the iPhone
            // actually visits it during the current trip.
            state.appendQueueStop(coordinate)
            refreshAnnotations(on: map)
        }

        // MARK: - Right-click context menu

        /// Last coordinate that the user right-clicked. Stashed so the
        /// `@objc` menu-item callbacks can read it without us inventing
        /// a custom `representedObject` packaging dance.
        private var contextMenuCoordinate: CLLocationCoordinate2D?

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            contextMenuCoordinate = coord

            let menu = makeContextMenu(at: coord)
            menu.popUp(positioning: nil, at: point, in: map)
        }

        // The NSMenu localisation workaround moved to
        // MapContextMenuPolicy.localized (v1.15.2 audit P12).

        /// Which rows exist and when each is enabled lives in
        /// `MapContextMenuPolicy`, shared with NativeMapView — that
        /// policy is what drifted between the two (v1.15.2 audit P12).
        /// Only the wiring is local: this view dispatches straight to
        /// its Coordinator, using `contextMenuCoordinate` captured at
        /// right-click time.
        private func makeContextMenu(at coord: CLLocationCoordinate2D) -> NSMenu {
            MapContextMenuPolicy.buildMenu(for: coord, state: state) { spec, item in
                item.target = self
                switch spec.action {
                case .teleport:       item.action = #selector(self.menuTeleport(_:))
                case .addStop:        item.action = #selector(self.menuAddStop(_:))
                case .copyCoordinate: item.action = #selector(self.menuCopyCoordinate(_:))
                case .bookmark:       item.action = #selector(self.menuAddBookmark(_:))
                }
            }
        }

        @objc func menuTeleport(_ sender: NSMenuItem) {
            guard let coord = contextMenuCoordinate,
                  let udid = state.selectedUDID else { return }
            Task { await state.teleport(udid: udid, lat: coord.latitude, lng: coord.longitude) }
        }

        @objc func menuAddStop(_ sender: NSMenuItem) {
            guard let coord = contextMenuCoordinate else { return }
            state.appendQueueStop(Coordinate(lat: coord.latitude, lng: coord.longitude))
            if let map = mapView {
                refreshAnnotations(on: map)
            }
        }

        @objc func menuCopyCoordinate(_ sender: NSMenuItem) {
            // 6-decimal precision matches what the status bar's
            // copy button uses, so a user copying coords from
            // either entry point gets the same string format.
            guard let coord = contextMenuCoordinate else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(
                String(format: "%.6f, %.6f", coord.latitude, coord.longitude),
                forType: .string,
            )
        }

        @objc func menuAddBookmark(_ sender: NSMenuItem) {
            guard let coord = contextMenuCoordinate else { return }
            // Hand the coordinate off to AppState; the sheet view
            // attached to MainView reacts to `pendingBookmarkCoord`
            // becoming non-nil.
            state.pendingBookmarkCoord =
                Coordinate(lat: coord.latitude, lng: coord.longitude)
        }

        func refreshAnnotations(on map: MKMapView) {
            // --- Random walk bounded centre disc ------------------------
            // Drawn while the user has the Random Walk panel open so they
            // can see exactly which area the iPhone will wander before
            // pressing Start. After Start, we switch over to the LIVE
            // walker's own centre + radius so the disc stays anchored
            // at the original Start position even after switching away
            // from this iPhone and back (v1.13.1: pre-fix, the disc
            // drifted onto the live position because RandomWalkPanel
            // kept rewriting `randomWalkPreviewCenter` to whatever
            // `simulatedLocation` happened to be when the walker was
            // restored).
            let rwCenter = state.randomWalk?.center ?? state.randomWalkPreviewCenter
            let rwRadius = state.randomWalk?.radiusM ?? state.randomWalkPreviewRadiusM
            let rwSig: (Coordinate, Double)? =
                (rwCenter != nil && rwRadius != nil) ? (rwCenter!, rwRadius!) : nil
            let rwSigChanged: Bool = {
                switch (rwSig, lastRWPreviewSignature) {
                case (nil, nil): return false
                case let (a?, b?): return a.0 != b.0 || abs(a.1 - b.1) > 0.5
                default: return true
                }
            }()
            if rwSigChanged {
                if let old = randomWalkPreviewCircle {
                    map.removeOverlay(old)
                    randomWalkPreviewCircle = nil
                }
                if let center = rwCenter, let radius = rwRadius {
                    let circle = MKCircle(
                        center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lng),
                        radius: radius
                    )
                    map.addOverlay(circle, level: .aboveLabels)
                    randomWalkPreviewCircle = circle
                }
                lastRWPreviewSignature = rwSig
            }

            // --- Preview polyline (faded) -------------------------------
            // Drawn while the user is still planning, BEFORE Navigate is
            // pressed. Same color/dash logic as the active route, but
            // thinner and translucent so the eye reads it as "what would
            // happen if I clicked Navigate" rather than a committed trip.
            // We add it FIRST so the active route, when present, layers
            // on top.
            let previewCoords = state.previewRoute
            let previewStraight = state.previewIsStraightLine
            let previewChanged = previewCoords != lastPreviewSignature
                || previewStraight != lastPreviewIsStraightLine
            if previewChanged {
                if let old = previewPolyline {
                    map.removeOverlay(old)
                    previewPolyline = nil
                }
                if !previewCoords.isEmpty {
                    let cl = previewCoords.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                    }
                    let line = StyledPolyline(coordinates: cl, count: cl.count)
                    line.isStraightLine = previewStraight
                    line.isPreview = true
                    map.addOverlay(line, level: .aboveLabels)
                    previewPolyline = line
                }
                lastPreviewSignature = previewCoords
                lastPreviewIsStraightLine = previewStraight
            }

            // --- Random walk planned path (purple dashed) --------------
            // The walker pre-generates ~5 minutes of upcoming targets and
            // we draw them so the user can see the actual route the
            // iPhone will take, rather than a vague "will wander
            // somewhere in this circle" disc.
            let rwPath = state.randomWalk?.plannedPath ?? []
            if rwPath != lastRWPathSignature {
                if let old = randomWalkPathPolyline {
                    map.removeOverlay(old)
                    randomWalkPathPolyline = nil
                }
                if rwPath.count >= 2 {
                    let cl = rwPath.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                    }
                    let line = StyledPolyline(coordinates: cl, count: cl.count)
                    line.kind = .randomWalk
                    map.addOverlay(line, level: .aboveLabels)
                    randomWalkPathPolyline = line
                }
                lastRWPathSignature = rwPath
            }

            // --- Active route polyline (orange) -------------------------
            // Drawn from `activeRoute` (set when Navigate is pressed and
            // kept until Restore / Teleport / next Navigate), so the line
            // remains on screen after Pause / Stop / arrival.
            //
            // Style mirrors the routing mode: straight-line trips render
            // as a dashed line so the visual confirms the mode without
            // the user having to look at any toggle.
            let routeCoords = state.activeRoute ?? []
            let isStraightLine = state.activeRouteIsStraightLine
            let routeChanged = routeCoords != lastRouteSignature
                || isStraightLine != lastRouteIsStraightLine
            if routeChanged {
                if let old = routePolyline {
                    map.removeOverlay(old)
                    routePolyline = nil
                }
                if !routeCoords.isEmpty {
                    let cl = routeCoords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                    let line = StyledPolyline(coordinates: cl, count: cl.count)
                    line.isStraightLine = isStraightLine
                    // aboveLabels (matching the OSM tile layer) so the
                    // polyline renders ON TOP of OSM tiles. aboveRoads
                    // would put it under the canReplaceMapContent tile.
                    map.addOverlay(line, level: .aboveLabels)
                    routePolyline = line
                }
                lastRouteSignature = routeCoords
                lastRouteIsStraightLine = isStraightLine
            }

            // --- Active destination flag (purple) -----------------------
            let destination = state.activeDestination
            if destination != lastDestinationSignature {
                if let old = destinationAnnotation {
                    map.removeAnnotation(old)
                    destinationAnnotation = nil
                }
                if let dest = destination {
                    let pin = DestinationAnnotation()
                    pin.coordinate = CLLocationCoordinate2D(latitude: dest.lat, longitude: dest.lng)
                    pin.title = "Destination"
                    pin.subtitle = String(format: "%.5f, %.5f", dest.lat, dest.lng)
                    map.addAnnotation(pin)
                    destinationAnnotation = pin
                }
                lastDestinationSignature = destination
            }

            // --- Search preview marker (orange) -------------------------
            // v1.11.2: the search bar's Preview action drops a marker
            // here so the user can see *where* they previewed instead
            // of just having the map silently pan. Same dirty-check
            // pattern as the destination flag — touch MapKit only when
            // the coord actually changes; nil → no marker.
            let previewMark = state.searchPreviewCoord
            if previewMark != lastSearchPreviewSig {
                if let old = searchPreviewAnnotation {
                    map.removeAnnotation(old)
                    searchPreviewAnnotation = nil
                }
                if let coord = previewMark {
                    let pin = SearchPreviewAnnotation()
                    pin.coordinate = CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lng)
                    pin.title = "Preview"
                    pin.subtitle = String(format: "%.5f, %.5f", coord.lat, coord.lng)
                    map.addAnnotation(pin)
                    searchPreviewAnnotation = pin
                }
                lastSearchPreviewSig = previewMark
            }

            // --- Pending stops + active waypoints (numbered pins) ------
            // Render BOTH the staging list (`pendingStops`, red, what the
            // user is composing right now) AND the captured waypoint list
            // (`activeWaypoints`, blue, what the iPhone is currently
            // walking through). After a Navigate kicks off, pendingStops
            // empties and activeWaypoints picks up the same coordinates;
            // the colour change tells the user "this trip is now live".
            //
            // v1.11.0: dirty-check guard. Previously this block did a
            // full wipe-and-rebuild on every `updateNSView` — fine for
            // a handful of stops, catastrophic for a 274-stop route
            // (548 MapKit add/remove ops per second, all on the main
            // thread). Now we only touch MapKit when the underlying
            // arrays actually change. Order matters within each list
            // (the annotation index encodes the stop number), so we
            // compare values + position via `!=`; same-content arrays
            // skip the rebuild entirely.
            // v1.11.0: once a Navigate fires, `activeWaypoints` carries
            // the live blue waypoints — we suppress `pendingStops` on
            // the map to avoid duplicate red+blue pins at every stop
            // (the staging panel keeps the coords list visible in the
            // sidebar regardless; this only affects map rendering).
            let pendingSig: [Coordinate] =
                state.activeWaypoints.isEmpty ? state.pendingStops : []
            let waypointsSig = state.activeWaypoints
            if pendingSig != lastPendingStopsSig || waypointsSig != lastActiveWaypointsSig {
                // Batch MapKit ops: removeAnnotations(_:) / addAnnotations(_:)
                // commit in a single map update, dramatically cheaper than
                // looping individual remove/add for long routes. The old
                // per-pin loop produced ~150 main-thread MapKit calls for a
                // 78-stop route — visible UI freeze when the user switched
                // mode (which clears activeWaypoints back to []) or hit
                // Navigate / Cancel. Batch ops keep the main thread free.
                if !pendingStopAnnotations.isEmpty {
                    map.removeAnnotations(pendingStopAnnotations)
                    pendingStopAnnotations.removeAll(keepingCapacity: true)
                }
                // Stop-pin decimation. Apple's MapKit chokes once the
                // on-map MKAnnotation count grows past ~100 because each
                // pin is a real NSView/CALayer with its own collision /
                // hit-test / pixel-position recompute per frame. For
                // recorded GPX tracks (1163-, 4000-pt routes) we'd
                // otherwise drop frames every pan/zoom.
                //
                // When the underlying stop list crosses
                // `decimationThreshold`, we render only:
                //   * stop #1 (start)
                //   * stop #N (end)
                //   * every `decimationStep`-th stop in between
                //
                // The displayed badge text keeps the ORIGINAL stop
                // number (1, 102, 203, …, 1163) so the user can still
                // see which leg of the route they're looking at. The
                // underlying `pendingStops` / `activeWaypoints` lists
                // are untouched — the daemon receives every single
                // stop and walks them all.
                let decimationThreshold = 100
                let decimationStep = 101
                func shouldRenderIndex(_ idx: Int, count: Int) -> Bool {
                    if count <= decimationThreshold { return true }
                    if idx == 0 { return true }
                    if idx == count - 1 { return true }
                    return idx % decimationStep == 0
                }
                var batch: [MKAnnotation] = []
                let pendingDecimated = pendingSig.count > decimationThreshold
                let waypointsDecimated = waypointsSig.count > decimationThreshold
                let pendingRenderEst = pendingDecimated
                    ? pendingSig.count / decimationStep + 2
                    : pendingSig.count
                let waypointsRenderEst = waypointsDecimated
                    ? waypointsSig.count / decimationStep + 2
                    : waypointsSig.count
                batch.reserveCapacity(pendingRenderEst + waypointsRenderEst)
                for (index, stop) in pendingSig.enumerated() {
                    guard shouldRenderIndex(index, count: pendingSig.count) else { continue }
                    let pin = StopAnnotation(stopNumber: index + 1, isActive: false)
                    pin.coordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lng)
                    pin.title = "Stop \(index + 1)"
                    pin.subtitle = String(format: "%.5f, %.5f", stop.lat, stop.lng)
                    batch.append(pin)
                    pendingStopAnnotations.append(pin)
                }
                for (index, stop) in waypointsSig.enumerated() {
                    guard shouldRenderIndex(index, count: waypointsSig.count) else { continue }
                    let pin = StopAnnotation(stopNumber: index + 1, isActive: true)
                    pin.coordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lng)
                    pin.title = "Waypoint \(index + 1)"
                    pin.subtitle = String(format: "%.5f, %.5f", stop.lat, stop.lng)
                    batch.append(pin)
                    pendingStopAnnotations.append(pin)
                }
                if !batch.isEmpty {
                    map.addAnnotations(batch)
                }
                lastPendingStopsSig = pendingSig
                lastActiveWaypointsSig = waypointsSig
            }

            // --- Simulated location (green) -----------------------------
            // Pull from `currentMapFocus`, which automatically
            // resolves to `browseCursor` in browse mode and
            // `simulatedLocation` for a real iPhone. This is
            // what fixes the "browse-pin contaminates iPhone
            // pin" bug — the two sources never cross.
            //
            // Position-only updates (1 Hz tick during simulation)
            // mutate the existing annotation's `coordinate` in place.
            // MKPointAnnotation's coordinate is KVO-compliant, so
            // MapKit smoothly slides the pin to the new lat/lng
            // without destroying and re-creating the annotation view.
            // The old "remove + add every tick" path showed a visible
            // flicker on macOS 26 Tahoe and contended for the main
            // thread during navigation — worse with longer routes
            // because each tick competed with route-polyline redraws.
            // Full rebuild fires only when the pin's KIND changes
            // (browse-only ↔ iPhone-simulated): different title /
            // colour / glyph applied in viewFor-annotation below.
            let focus = state.currentMapFocus
            let isVirtual = state.isVirtualMapSelected
            let prevKind: Bool? = lastSimulatedSig?.1

            if focus == nil {
                if let old = simulatedAnnotation {
                    map.removeAnnotation(old)
                    simulatedAnnotation = nil
                }
                lastSimulatedSig = nil
            } else if let existing = simulatedAnnotation, prevKind == isVirtual {
                let lat = focus!.lat
                let lng = focus!.lng
                if existing.coordinate.latitude != lat || existing.coordinate.longitude != lng {
                    existing.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    existing.subtitle = String(format: "%.5f, %.5f", lat, lng)
                }
                lastSimulatedSig = (focus!, isVirtual)
            } else {
                if let old = simulatedAnnotation {
                    map.removeAnnotation(old)
                }
                let pin = SimulatedAnnotation()
                pin.coordinate = CLLocationCoordinate2D(latitude: focus!.lat, longitude: focus!.lng)
                // Browse-only Map mode uses the pin to mean "where
                // the user clicked" — there's no iPhone being
                // simulated. Label it "You" instead. The
                // viewFor-annotation switch below picks a different
                // glyph + colour for the same reason.
                pin.title = isVirtual
                    ? String(localized: "You",
                             comment: "Map pin label in browse-only Map mode — \"you are here\"")
                    : "iPhone (simulated)"
                pin.subtitle = String(format: "%.5f, %.5f", focus!.lat, focus!.lng)
                map.addAnnotation(pin)
                simulatedAnnotation = pin
                lastSimulatedSig = (focus!, isVirtual)
            }

            // --- Mac proxy location (blue dot) --------------------------
            // Hidden while we have a simulated/browse pin: the green
            // pin already shows the "current location" the user
            // should be tracking. Two dots would imply the iPhone is
            // in two places at once. We check `currentMapFocus` (not
            // just `simulatedLocation`) so the Mac puck also hides
            // in browse mode after the user has clicked a point.
            //
            // v1.11.0 guard: same pattern as the simulated pin — skip
            // MapKit work entirely when the visible coord + accuracy
            // haven't changed since the last refresh. The first-fix
            // recenter is hoisted out of the rebuild branch so it
            // still fires on the initial appearance.
            //
            // v1.11.2 round 19 perf fix: ONLY read state.macLocation
            // when the Mac annotation is actually going to render
            // (macHidden == false). Previously `state.macLocation.accuracy`
            // was read unconditionally, which registered MapContainerView
            // as an observer of the CoreLocation 1 Hz publisher even
            // when a simulated/browse pin had taken visual focus — so
            // every Mac location tick fired updateNSView during a
            // drag, stuttering the pan. Now in device-connected mode
            // (currentMapFocus != nil) MapContainerView is fully
            // decoupled from the CoreLocation publisher.
            let macHidden = state.currentMapFocus != nil
            let macCoord: Coordinate?
            let macAcc: Double?
            if macHidden {
                macCoord = nil
                macAcc = nil
            } else if let c = state.macLocation.coordinate {
                macCoord = Coordinate(lat: c.latitude, lng: c.longitude)
                macAcc = state.macLocation.accuracy
            } else {
                macCoord = nil
                macAcc = nil
            }
            let macSig: (Coordinate, Double?)? = macCoord.map { ($0, macAcc) }
            let macSigChanged: Bool = {
                switch (macSig, lastMacSig) {
                case (nil, nil): return false
                case let (a?, b?): return a.0 != b.0 || a.1 != b.1
                default: return true
                }
            }()
            if macSigChanged {
                if let old = macAnnotation {
                    map.removeAnnotation(old)
                    macAnnotation = nil
                }
                if !macHidden, let mac = state.macLocation.coordinate {
                    let pin = MacAnnotation()
                    pin.coordinate = mac
                    pin.title = "Mac location (≈ iPhone real GPS)"
                    if let acc = macAcc {
                        pin.subtitle = String(format: "≈ %.0f m", acc)
                    }
                    map.addAnnotation(pin)
                    macAnnotation = pin

                    // Centre once on first fix so the user sees something useful
                    // instead of the default Taipei region. Subsequent updates
                    // do not recenter -- the user may have panned away on
                    // purpose.
                    if !didCenterOnMac {
                        didCenterOnMac = true
                        let region = MKCoordinateRegion(
                            center: mac,
                            latitudinalMeters: 2_500,
                            longitudinalMeters: 2_500
                        )
                        map.setRegion(region, animated: true)
                    }
                }
                lastMacSig = macSig
            }
        }

        // MARK: MKMapViewDelegate

        /// Throttle handle for `regionDidChange` saves — we don't want
        /// to write the SwiftData store on every pixel of the user's
        /// pan, but we DO want the latest region to land within ~half
        /// a second of them stopping moving.
        ///
        /// v1.11.2 drag-lag fix: MKMapView fires `regionDidChange`
        /// continuously at display-link cadence (~60 Hz) during a
        /// drag. The old approach cancelled + recreated a Swift
        /// Concurrency Task on EVERY call — ~60 allocations/sec. The
        /// pattern now uses a separate `regionChanging` flag to gate
        /// Task creation: `regionWillChange` arms the flag, and only
        /// ONE new Task is created when the flag transitions. During
        /// the drag every `regionDidChange` call just snapshots the
        /// latest region into `pendingCenter/pendingSpan` (cheap
        /// value writes); the single pending Task reads those values
        /// when its 500 ms timer fires.
        private var saveCameraTask: Task<Void, Never>?
        private var regionChanging = false
        // Set to true just before applyPendingFly calls setRegion so
        // that the resulting regionWillChange / regionDidChange pair is
        // NOT treated as a user-initiated pan. Programmatic follow
        // ticks fire at 1 Hz during navigation — saving the camera
        // on every tick floods the SwiftData WAL and causes app-wide
        // lag within a few minutes. User-initiated pans (flag is false
        // when the delegate fires) still go through the save path.
        private var applyingProgrammaticFly = false
        private var pendingCenter = CLLocationCoordinate2D()
        private var pendingSpan: Double = 0

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if !applyingProgrammaticFly { regionChanging = true }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Always snapshot the latest region so the Task has fresh
            // values whenever it finally fires.
            pendingCenter = mapView.region.center
            pendingSpan   = mapView.region.span.latitudeDelta * 111_000

            // LOD: badge ↔ dot switch only triggers re-add when the
            // user actually crosses the threshold, so a small pan
            // within either zone is free. When crossing, we remove +
            // re-add only the StopAnnotations (preserving other
            // overlays + the simulated puck untouched) — MapKit re-
            // dispatches viewFor on add, picking the new variant.
            let zoomedInNow = Self.isZoomedInForLODCheck(mapView)
            if zoomedInNow != lastLODZoomedIn, !pendingStopAnnotations.isEmpty {
                lastLODZoomedIn = zoomedInNow
                let snapshot = pendingStopAnnotations
                mapView.removeAnnotations(snapshot)
                mapView.addAnnotations(snapshot)
            } else {
                lastLODZoomedIn = zoomedInNow
            }

            guard regionChanging else { return }
            regionChanging = false

            saveCameraTask?.cancel()
            saveCameraTask = Task { [weak self] in
                // Shared with NativeMapView (v1.15.2 audit P12). This
                // was 500 ms here and, until the P3 fix, 500 ms there
                // too — shorter than the 1 Hz follow tick, so it could
                // never coalesce one.
                try? await Task.sleep(for: CameraPersistencePolicy.saveDebounce)
                guard !Task.isCancelled, let self else { return }
                self.state.saveMapCamera(
                    centerLat: self.pendingCenter.latitude,
                    centerLng: self.pendingCenter.longitude,
                    spanMeters: self.pendingSpan / 2,
                )
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let s2 = overlay as? S2GridPolyline {
                let r = MKPolylineRenderer(polyline: s2)
                r.strokeColor = NSColor.systemIndigo.withAlphaComponent(0.6)
                r.lineWidth = s2.s2Level >= 18 ? 0.6
                            : s2.s2Level >= 16 ? 0.8
                            : 1.1
                r.lineCap = .butt
                r.lineJoin = .round
                return r
            }
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.fillColor = NSColor.systemPurple.withAlphaComponent(0.12)
                r.strokeColor = NSColor.systemPurple.withAlphaComponent(0.7)
                r.lineWidth = 2
                r.lineDashPattern = [6, 4]
                return r
            }
            if let styled = overlay as? StyledPolyline {
                let renderer = MKPolylineRenderer(polyline: styled)
                switch styled.kind {
                case .randomWalk:
                    renderer.strokeColor = NSColor.systemPurple.withAlphaComponent(0.85)
                    renderer.lineDashPattern = [4, 4]
                    renderer.lineWidth = 3
                default:
                    let baseColor: NSColor = styled.isStraightLine ? .systemTeal : .systemOrange
                    let alpha: CGFloat = styled.isPreview ? 0.55 : 0.95
                    renderer.strokeColor = baseColor.withAlphaComponent(alpha)
                    renderer.lineWidth = styled.isPreview ? 4 : 5
                    if styled.isStraightLine {
                        renderer.lineDashPattern = styled.isPreview ? [6, 4] : [10, 6]
                    }
                }
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.85)
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is MacAnnotation:
                let id = "mac"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.canShowCallout = true
                v.image = Self.macPuckImage
                v.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
                v.centerOffset = .zero
                return v

            case is SimulatedAnnotation:
                // Earlier rounds used MKMarkerAnnotationView with
                // markerTintColor + glyphImage. Pan-while-static
                // profiling showed MapKit doing significant per-frame
                // render work for the styled marker (~26 % of main
                // thread in renderSceneSync), evident from the
                // user-reported "smooth before first teleport, laggy
                // after" pattern — pre-teleport the map shows
                // MacAnnotation (image-based, cheap) and pans
                // smoothly; post-teleport the simulated pin's marker
                // view became the new render hot path. Match
                // MacAnnotation's lightweight image-based approach
                // (precomputed NSImage, plain MKAnnotationView) and
                // the per-frame cost drops back to the pre-teleport
                // baseline.
                let isBrowse = state.isVirtualMapSelected
                let id = isBrowse ? "sim-you" : "sim-iphone"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.image = isBrowse ? Self.browseSimulatedPuckImage
                                   : Self.realSimulatedPuckImage
                v.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
                v.centerOffset = .zero
                v.canShowCallout = true
                // .required + .max kept the marker on top of stop pins
                // and the route polyline. With the image-based view
                // we still need that — Z-priority is fine, but the
                // expensive ".required" collision opt-out is dropped
                // (single puck has no collision; the cost was the
                // per-frame render check the marker view tied into).
                v.zPriority = .max
                return v

            case let stop as StopAnnotation:
                // Two visual variants on the same annotation class
                // so the user can tell staging (red) apart from
                // active waypoints (blue) at a glance:
                //
                //   * isActive = false → red, staging stop the
                //     user just clicked. Disappears the moment
                //     they hit Navigate.
                //   * isActive = true  → blue, waypoint captured
                //     into `activeWaypoints` at navigation start;
                //     stays drawn while the iPhone walks the trip.
                //
                // Zoom-aware level-of-detail: at city / regional zoom
                // a 1000-pt GPX track turns into a wall of overlapping
                // MKMarkerAnnotationViews — each one rasterises a
                // unique numbered badge image and MapKit hit-tests
                // them per gesture, freezing the main thread. When
                // the map is zoomed out (more than ~3 km of latitude
                // visible) we fall back to a cheap precomputed
                // coloured dot image; numbers come back as soon as
                // the user zooms in enough to read them.
                let id: String
                let useNumberedBadge = Self.isZoomedInForLODCheck(mapView)
                if useNumberedBadge {
                    id = stop.isActive ? "stop-active" : "stop-staging"
                } else {
                    id = stop.isActive ? "stop-active-dot" : "stop-staging-dot"
                }
                if useNumberedBadge {
                    let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                        ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                    v.annotation = annotation
                    v.markerTintColor = stop.isActive ? .systemBlue : .systemRed
                    v.glyphText = "\(stop.stopNumber)"
                    v.canShowCallout = true
                    // .required opts stop pins out of MapKit's
                    // collision-avoidance pool. Without this, stops
                    // that are geographically close (common in dense
                    // walking routes) are silently hidden — the user
                    // sees 6 pins for a 7-stop route with no
                    // indication one is missing.
                    v.displayPriority = .required
                    return v
                } else {
                    let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                        ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                    v.annotation = annotation
                    v.image = stop.isActive ? Self.activeStopDotImage : Self.stagingStopDotImage
                    v.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
                    v.centerOffset = .zero
                    v.canShowCallout = false
                    // Dots stay opted INTO collision so MapKit can
                    // hide overlapping ones at extreme zoom-outs;
                    // visual density there reads as a coloured trail
                    // not a stack of dots.
                    v.displayPriority = .defaultHigh
                    return v
                }

            case is DestinationAnnotation:
                let id = "dst"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemPurple
                v.glyphImage = NSImage(systemSymbolName: "flag.checkered", accessibilityDescription: nil)
                v.canShowCallout = true
                return v

            case is SearchPreviewAnnotation:
                // v1.11.2: orange marker with magnifying-glass glyph
                // — visually distinct from staging stops (red), live
                // waypoints (blue), destination (purple), and the
                // simulated puck (green / blue). Picked orange so a
                // user previewing across an active route still sees
                // both at a glance.
                let id = "search-preview"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemOrange
                v.glyphImage = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                v.canShowCallout = true
                return v

            case let bm as BookmarkAnnotation:
                // v1.17: tinted per category rather than a flat indigo.
                // With 3 000+ bookmarks the colour is the only thing
                // separating them once the labels collapse, so a single
                // tint wasted the one channel that still reads at low
                // zoom. Same `CategoryPalette` values the sidebar and
                // the SwiftUI map use -- one source, three renderers.
                // Clustering keeps the map readable; displayPriority
                // .defaultLow yields the simulated puck + active
                // waypoints when stacks form.
                let id = "bookmark"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = CategorySwatch.nsColor(bm.colorHex)
                // The glyph is a template image, so the marker tints it
                // with the category colour above -- one colour source,
                // one set of petal discs, whichever renderer draws it.
                if let id = bm.flowerID,
                   let design = FlowerPin.designs.first(where: { $0.id == id }) {
                    v.glyphImage = FlowerGlyph.image(for: design)
                } else {
                    v.glyphImage = NSImage(systemSymbolName: "bookmark.fill",
                                           accessibilityDescription: nil)
                }
                v.canShowCallout = true
                v.clusteringIdentifier = "bookmark"
                v.displayPriority = .defaultLow
                // Right callout accessory — only when the bookmark has
                // a photo to show. Tapping the button is intercepted by
                // `calloutAccessoryControlTapped:` below and surfaces
                // the photo sheet.
                if bm.hasImage {
                    let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
                    btn.bezelStyle = .accessoryBarAction
                    btn.isBordered = false
                    btn.image = NSImage(systemSymbolName: "photo",
                                        accessibilityDescription: "View photo")
                    btn.title = ""
                    v.rightCalloutAccessoryView = btn
                } else {
                    v.rightCalloutAccessoryView = nil
                }
                return v

            default:
                return nil
            }
        }

        /// Trigger the photo-preview sheet when the user taps the
        /// callout's photo button on a bookmark pin. The lookup goes
        /// back through the SwiftData context so we get the live
        /// Bookmark instance the @Model UI is bound to.
        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            calloutAccessoryControlTapped control: NSControl,
        ) {
            guard let ann = view.annotation as? BookmarkAnnotation,
                  let ctx = state.bookmarkFetchContext
            else { return }
            let pid = ann.persistentID
            let predicate = #Predicate<Bookmark> { $0.persistentModelID == pid }
            var descriptor = FetchDescriptor<Bookmark>(predicate: predicate)
            descriptor.fetchLimit = 1
            if let match = (try? ctx.fetch(descriptor))?.first {
                state.mapPreviewingBookmark = match
            }
        }

        // Stop-pin LOD ───────────────────────────────────────────────
        //
        // Threshold expressed as latitude delta of the visible region.
        // Below 0.03° (~3 km tall) we draw the heavy numbered MKMarker
        // badge; above it we drop to a precomputed 10×10 coloured dot
        // so a 4000-pt GPX track stays fluid when viewed at city scale.
        // 0.03° is chosen empirically — at typical walking-route street
        // density the numbered badges remain readable; above this users
        // can't tell adjacent stops apart anyway, so trading the digit
        // for a dot is information-neutral.
        private static let stopLODLatitudeDelta: CLLocationDegrees = 0.03
        static func isZoomedInForLODCheck(_ mapView: MKMapView) -> Bool {
            return mapView.region.span.latitudeDelta <= stopLODLatitudeDelta
        }
        /// Tracks the LOD state at the last region change. When the
        /// user pans / zooms through the threshold, the
        /// `regionDidChange` handler removes + re-adds annotations so
        /// `viewFor` re-fires and the renderer swaps badge ↔ dot.
        private var lastLODZoomedIn: Bool = true

        // 10×10 coloured dot precomputed once. Cheap NSImage drawn into
        // the annotation view's `image` slot — no glyph rasterisation,
        // no collision-priority work, no MKMarker shadow. Two tints
        // mirror the badge variants so the dots colour-code the same
        // staging-vs-active distinction.
        private static let activeStopDotImage: NSImage = {
            makeStopDot(body: .systemBlue)
        }()
        private static let stagingStopDotImage: NSImage = {
            makeStopDot(body: .systemRed)
        }()
        private static func makeStopDot(body: NSColor) -> NSImage {
            let size = NSSize(width: 10, height: 10)
            let image = NSImage(size: size)
            image.lockFocus()
            // Subtle white border keeps the dot legible against both
            // light and dark map tiles.
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 10, height: 10)).fill()
            body.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
            image.unlockFocus()
            return image
        }

        // Cached blue puck so we don't redraw it every annotation view.
        private static let macPuckImage: NSImage = {
            let size = NSSize(width: 22, height: 22)
            let image = NSImage(size: size)
            image.lockFocus()
            // Outer halo
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 22, height: 22)).fill()
            // Inner solid dot with white border
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 14, height: 14)).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.5, y: 5.5, width: 11, height: 11)).fill()
            image.unlockFocus()
            return image
        }()

        /// Real-iPhone simulated puck (green halo + ring + body, white
        /// "iPhone"-ish glyph). Precomputed so the SimulatedAnnotation
        /// view stays cheap to render — same trick MacAnnotation uses.
        private static let realSimulatedPuckImage: NSImage = {
            makeSimulatedPuck(body: .systemGreen, glyph: "iphone")
        }()

        /// Browse-mode (virtual Map device) puck — blue halo + person
        /// glyph. Same shape as real-iPhone variant so the on-map
        /// footprint is identical; only colour + glyph distinguish.
        private static let browseSimulatedPuckImage: NSImage = {
            makeSimulatedPuck(body: .systemBlue, glyph: "person.fill")
        }()

        /// Draw a 28×28 puck with `body` colour and a centred white
        /// SF Symbol glyph. Lock-focus-based; called once per
        /// variant at first access (the cached `let`s above).
        private static func makeSimulatedPuck(body: NSColor, glyph: String) -> NSImage {
            let size = NSSize(width: 28, height: 28)
            let image = NSImage(size: size)
            image.lockFocus()
            body.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 28, height: 28)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 20, height: 20)).fill()
            body.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 16, height: 16)).fill()
            // White SF-symbol glyph centred inside the body. We pull
            // the symbol image, tint it via a palette config to a
            // single white colour, then composite it at the centre.
            if let raw = NSImage(systemSymbolName: glyph, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                    .applying(.init(paletteColors: [.white]))
                let tinted = raw.withSymbolConfiguration(config) ?? raw
                let gSize = tinted.size
                let r = NSRect(x: (28 - gSize.width) / 2,
                               y: (28 - gSize.height) / 2,
                               width: gSize.width,
                               height: gSize.height)
                tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            image.unlockFocus()
            return image
        }
    }
}

// MARK: - Annotation classes (used only for type-discrimination in viewFor)

private final class StopAnnotation: MKPointAnnotation {
    let stopNumber: Int
    /// false → staging pin (red), true → live waypoint pin (blue).
    /// Read by `viewFor:` to pick the marker tint.
    let isActive: Bool
    init(stopNumber: Int, isActive: Bool = false) {
        self.stopNumber = stopNumber
        self.isActive = isActive
        super.init()
    }
}
private final class SimulatedAnnotation: MKPointAnnotation {}
private final class MacAnnotation: MKPointAnnotation {}
private final class DestinationAnnotation: MKPointAnnotation {}


/// Marker dropped per saved bookmark when the user toggles "Show
/// bookmarks on map" in the layer picker. Carries the SwiftData
/// persistent id so the click-handler can resolve the matching
/// `Bookmark` model object on demand and present its photo sheet.
private final class BookmarkAnnotation: MKPointAnnotation {
    let persistentID: PersistentIdentifier
    /// Cached at sync time so the callout accessory view can decide
    /// whether to render a "view photo" button without re-fetching
    /// the Bookmark per render pass.
    var hasImage: Bool
    /// Category colour, resolved at sync time for the same reason:
    /// `viewFor:` runs per pin per pass and must not reach back into
    /// AppState for a lookup it can be handed.
    var colorHex: String
    /// Flower design id, or nil when this bookmark carries an SF
    /// Symbol (every bookmark made before v1.17 does).
    var flowerID: String?
    init(persistentID: PersistentIdentifier, hasImage: Bool,
         colorHex: String, flowerID: String?) {
        self.persistentID = persistentID
        self.hasImage = hasImage
        self.colorHex = colorHex
        self.flowerID = flowerID
        super.init()
    }
}
/// v1.11.2: marker dropped by the search bar's Preview action so the
/// user actually sees where they previewed. Cleared by teleport /
/// navigate / a new preview (the previous marker just relocates).
private final class SearchPreviewAnnotation: MKPointAnnotation {}

/// MKPolyline carrying the small bit of metadata the renderer needs to
/// distinguish straight-line trips from OSRM road routes, previews from
/// active trips, and random-walk paths from navigation routes.
/// Subclassing is the simplest way to attach flags that survive
/// MKMapView's overlay dispatch back into `rendererFor:`.
private final class StyledPolyline: MKPolyline {
    enum Kind { case route, randomWalk }
    var kind: Kind = .route
    var isStraightLine: Bool = false
    /// True when this polyline shows the user's *next* trip (rendered
    /// thinner and translucent), false when it's the *active* one.
    var isPreview: Bool = false
}

/// MKPolyline subclass tagged with the S2 grid level it belongs to.
/// One per horizontal or vertical scanline traversing the visible
/// viewport — see `S2GridEnumerator.gridLines` for why we draw at
/// the scanline granularity instead of per-cell.
final class S2GridPolyline: MKPolyline {
    var s2Level: Int = 17
}
