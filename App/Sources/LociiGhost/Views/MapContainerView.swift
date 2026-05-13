import SwiftUI
import MapKit
import CoreLocation

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
        return map
    }

    func updateNSView(_ nsView: MKMapView, context: Context) {
        context.coordinator.state = state
        context.coordinator.refreshAnnotations(on: nsView)
        context.coordinator.applyPendingFly(on: nsView)
        // Cheap idempotence: applyTileLayer no-ops when the layer
        // hasn't changed, so calling it on every state update is fine.
        Coordinator.applyTileLayer(state.mapTileLayer, to: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var state: AppState
        weak var mapView: MKMapView?
        private var pendingStopAnnotations: [StopAnnotation] = []
        private var simulatedAnnotation: SimulatedAnnotation?
        private var macAnnotation: MacAnnotation?
        private var destinationAnnotation: DestinationAnnotation?
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
        private var didCenterOnMac = false
        private var lastServicedFlyID: UUID?

        init(state: AppState) {
            self.state = state
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
            if req.preserveZoom {
                // Follow-puck path: keep the user's current span,
                // only shift the centre. setRegion-with-current-
                // span would jitter on rapid updates; passing the
                // map's existing `region.span` keeps zoom stable.
                region = MKCoordinateRegion(center: center, span: map.region.span)
            } else {
                region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: req.spanMeters,
                    longitudinalMeters: req.spanMeters,
                )
            }
            // Animation length is fine for one-shot teleports
            // (200-300 ms is unnoticed) and looks smooth for
            // 1 Hz follow updates (the next animation overlaps
            // the previous one — MKMapView coalesces).
            map.setRegion(region, animated: true)
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
            // Stop-adding only when Multi-stop mode is the active
            // panel. Without this gate every stray map click would
            // sprout a red pin even when the user is just panning
            // around looking for somewhere to teleport — a real
            // annoyance the previous version surfaced. Right-click
            // ALWAYS pops the context menu (see `handleRightClick`),
            // so there's still a one-step "add as stop" path
            // available regardless of mode.
            guard state.activeMovementMode == .multiStop else { return }
            // Append rather than replace so successive clicks build a
            // multi-stop trip. The control panel exposes a clear / undo
            // affordance for getting out of this mode.
            state.pendingStops.append(coordinate)
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

        /// Look up a localized string for use in an NSMenu, honouring
        /// the user's `appLanguage` picker. Required because:
        ///
        ///   * NSMenu is AppKit — `\.locale` SwiftUI environment doesn't
        ///     reach it
        ///   * `String(localized: …)` uses `Bundle.main.preferredLocalizations`,
        ///     which we've forced to `[zh-Hant, en]` at app init (for
        ///     MapKit Chinese labels). Without this helper, every menu
        ///     item would silently lock to zh-Hant.
        ///
        /// We read `appLanguage` straight from UserDefaults (that's where
        /// `@AppStorage` lives). `.system` falls back to `Bundle.main`,
        /// which honours the AppleLanguages override above.
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

        private func makeContextMenu(at coord: CLLocationCoordinate2D) -> NSMenu {
            let menu = NSMenu()

            // Coordinate header — disabled so it reads as info, not action.
            let header = NSMenuItem()
            header.title = String(format: "📍  %.5f, %.5f", coord.latitude, coord.longitude)
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            let isConnected = state.devices
                .first(where: { $0.udid == state.selectedUDID })?
                .connected ?? false

            let teleport = NSMenuItem(
                title: menuString("Teleport here"),
                action: #selector(menuTeleport(_:)),
                keyEquivalent: ""
            )
            teleport.target = self
            teleport.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
            teleport.isEnabled = isConnected
            if !isConnected {
                teleport.toolTip = menuString("Connect a device first.")
            }
            menu.addItem(teleport)

            let addStop = NSMenuItem(
                title: menuString("Add as stop"),
                action: #selector(menuAddStop(_:)),
                keyEquivalent: ""
            )
            addStop.target = self
            addStop.image = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: nil)
            menu.addItem(addStop)

            // Copy-coordinates lands right after the action items
            // (Teleport / Add stop) and before the bookmark
            // section. Puts the user's mental model in the order
            // "do something with this point" → "remember this
            // point" without forcing them to scan the whole menu.
            let copyCoord = NSMenuItem(
                title: menuString("Copy coordinates"),
                action: #selector(menuCopyCoordinate(_:)),
                keyEquivalent: "",
            )
            copyCoord.target = self
            copyCoord.image = NSImage(systemSymbolName: "doc.on.doc",
                                      accessibilityDescription: nil)
            menu.addItem(copyCoord)

            menu.addItem(.separator())

            let addBookmark = NSMenuItem(
                title: menuString("Save as bookmark…"),
                action: #selector(menuAddBookmark(_:)),
                keyEquivalent: ""
            )
            addBookmark.target = self
            addBookmark.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
            menu.addItem(addBookmark)

            return menu
        }

        @objc func menuTeleport(_ sender: NSMenuItem) {
            guard let coord = contextMenuCoordinate,
                  let udid = state.selectedUDID else { return }
            Task { await state.teleport(udid: udid, lat: coord.latitude, lng: coord.longitude) }
        }

        @objc func menuAddStop(_ sender: NSMenuItem) {
            guard let coord = contextMenuCoordinate else { return }
            state.pendingStops.append(Coordinate(lat: coord.latitude, lng: coord.longitude))
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
            // --- Random walk preview disc -------------------------------
            // Drawn while the user has the Random Walk panel open so they
            // can see exactly which area the iPhone will wander before
            // pressing Start. Cleared when the panel closes or a real
            // walker takes over.
            let rwCenter = state.randomWalkPreviewCenter
            let rwRadius = state.randomWalkPreviewRadiusM
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

            // --- Pending stops + active waypoints (numbered pins) ------
            // Wipe the previous batch wholesale -- order matters and is
            // encoded in the annotation index, so we'd rather rebuild than
            // try to diff stop-by-stop.
            //
            // Render BOTH the staging list (`pendingStops`, red, what the
            // user is composing right now) AND the captured waypoint list
            // (`activeWaypoints`, blue, what the iPhone is currently
            // walking through). After a Navigate kicks off, pendingStops
            // empties and activeWaypoints picks up the same coordinates;
            // the colour change tells the user "this trip is now live".
            for old in pendingStopAnnotations {
                map.removeAnnotation(old)
            }
            pendingStopAnnotations.removeAll(keepingCapacity: true)
            for (index, stop) in state.pendingStops.enumerated() {
                let pin = StopAnnotation(stopNumber: index + 1, isActive: false)
                pin.coordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lng)
                pin.title = "Stop \(index + 1)"
                pin.subtitle = String(format: "%.5f, %.5f", stop.lat, stop.lng)
                map.addAnnotation(pin)
                pendingStopAnnotations.append(pin)
            }
            for (index, stop) in state.activeWaypoints.enumerated() {
                let pin = StopAnnotation(stopNumber: index + 1, isActive: true)
                pin.coordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lng)
                pin.title = "Waypoint \(index + 1)"
                pin.subtitle = String(format: "%.5f, %.5f", stop.lat, stop.lng)
                map.addAnnotation(pin)
                pendingStopAnnotations.append(pin)
            }

            // --- Simulated location (green) -----------------------------
            if let old = simulatedAnnotation {
                map.removeAnnotation(old)
                simulatedAnnotation = nil
            }
            // Pull from `currentMapFocus`, which automatically
            // resolves to `browseCursor` in browse mode and
            // `simulatedLocation` for a real iPhone. This is
            // what fixes the "browse-pin contaminates iPhone
            // pin" bug — the two sources never cross.
            if let sim = state.currentMapFocus {
                let pin = SimulatedAnnotation()
                pin.coordinate = CLLocationCoordinate2D(latitude: sim.lat, longitude: sim.lng)
                // Browse-only Map mode uses the pin to mean "where
                // the user clicked" — there's no iPhone being
                // simulated. Label it "You" instead. The
                // viewFor-annotation switch below picks a different
                // glyph + colour for the same reason.
                pin.title = state.isVirtualMapSelected
                    ? String(localized: "You",
                             bundle: .module,
                             comment: "Map pin label in browse-only Map mode — \"you are here\"")
                    : "iPhone (simulated)"
                pin.subtitle = String(format: "%.5f, %.5f", sim.lat, sim.lng)
                map.addAnnotation(pin)
                simulatedAnnotation = pin
            }

            // --- Mac proxy location (blue dot) --------------------------
            // Hidden while we have a simulated/browse pin: the green
            // pin already shows the "current location" the user
            // should be tracking. Two dots would imply the iPhone is
            // in two places at once. We check `currentMapFocus` (not
            // just `simulatedLocation`) so the Mac puck also hides
            // in browse mode after the user has clicked a point.
            let macHidden = state.currentMapFocus != nil
            if let old = macAnnotation {
                map.removeAnnotation(old)
                macAnnotation = nil
            }
            if !macHidden, let mac = state.macLocation.coordinate {
                let pin = MacAnnotation()
                pin.coordinate = mac
                pin.title = "Mac location (≈ iPhone real GPS)"
                if let acc = state.macLocation.accuracy {
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
        }

        // MARK: MKMapViewDelegate

        /// Throttle handle for `regionDidChange` saves — we don't want
        /// to write the SwiftData store on every pixel of the user's
        /// pan, but we DO want the latest region to land within ~half
        /// a second of them stopping moving. The Task is cancelled
        /// and replaced on every region change; only the last one's
        /// timer ever fires the save.
        private var saveCameraTask: Task<Void, Never>?

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            saveCameraTask?.cancel()
            // Capture the region NOW (not in the deferred task) so we
            // persist what the map looks like at the end of the
            // user's interaction, not whatever it has drifted to half
            // a second later.
            let center = mapView.region.center
            let span = mapView.region.span.latitudeDelta * 111_000  // ° → m
            saveCameraTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                self?.state.saveMapCamera(
                    centerLat: center.latitude,
                    centerLng: center.longitude,
                    spanMeters: span / 2,           // store half-span
                )
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
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
                // Two visual variants on the same pin so a quick
                // glance tells the user what mode they're in:
                //
                //   * Real iPhone selected → green pin + iPhone
                //     glyph (the legacy look)
                //   * Browse-only Map device → blue pin + person
                //     glyph; the label above also flips to "You"
                //
                // Use distinct dequeue identifiers per variant so
                // a recycled view never carries the wrong glyph
                // / colour over from the previous mode.
                let isBrowse = state.isVirtualMapSelected
                let id = isBrowse ? "sim-you" : "sim-iphone"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                if isBrowse {
                    v.markerTintColor = .systemBlue
                    v.glyphImage = NSImage(systemSymbolName: "person.fill",
                                           accessibilityDescription: nil)
                } else {
                    v.markerTintColor = .systemGreen
                    v.glyphImage = NSImage(systemSymbolName: "iphone",
                                           accessibilityDescription: nil)
                }
                v.canShowCallout = true
                // The simulated-iPhone pin sits on TOP of the route
                // polyline — the user always needs to see where their
                // device currently is, especially during playback when
                // pin and orange route line share the same coordinate.
                //
                // `displayPriority = .required` keeps the marker out
                // of MapKit's collision-collapse pool (otherwise nearby
                // stop pins can hide it).
                // `zPriority = .max` pulls it above all other
                // annotations in the layer-Z stacking order.
                v.displayPriority = .required
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
                // Use distinct dequeue ids so a recycled view
                // never carries the wrong tint over.
                let id = stop.isActive ? "stop-active" : "stop-staging"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = stop.isActive ? .systemBlue : .systemRed
                v.glyphText = "\(stop.stopNumber)"
                v.canShowCallout = true
                return v

            case is DestinationAnnotation:
                let id = "dst"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemPurple
                v.glyphImage = NSImage(systemSymbolName: "flag.checkered", accessibilityDescription: nil)
                v.canShowCallout = true
                return v

            default:
                return nil
            }
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
