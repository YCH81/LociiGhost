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
        map.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
            latitudinalMeters: 4_000,
            longitudinalMeters: 4_000
        )

        let osm = MKTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        osm.canReplaceMapContent = true
        map.addOverlay(osm, level: .aboveLabels)

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

        func applyPendingFly(on map: MKMapView) {
            guard let req = state.pendingMapFly, req.id != lastServicedFlyID else { return }
            lastServicedFlyID = req.id
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: req.coordinate.lat,
                    longitude: req.coordinate.lng
                ),
                latitudinalMeters: req.spanMeters,
                longitudinalMeters: req.spanMeters
            )
            map.setRegion(region, animated: true)
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            // Append rather than replace so successive clicks build a
            // multi-stop trip. The control panel exposes a clear / undo
            // affordance for getting out of this mode.
            state.pendingStops.append(Coordinate(lat: coord.latitude, lng: coord.longitude))
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
                title: "Teleport here",
                action: #selector(menuTeleport(_:)),
                keyEquivalent: ""
            )
            teleport.target = self
            teleport.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
            teleport.isEnabled = isConnected
            if !isConnected {
                teleport.toolTip = "Connect a device first."
            }
            menu.addItem(teleport)

            let addStop = NSMenuItem(
                title: "Add as stop",
                action: #selector(menuAddStop(_:)),
                keyEquivalent: ""
            )
            addStop.target = self
            addStop.image = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: nil)
            menu.addItem(addStop)

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

            // --- Pending stops (red, numbered) --------------------------
            // Wipe the previous batch wholesale -- order matters and is
            // encoded in the annotation index, so we'd rather rebuild than
            // try to diff stop-by-stop.
            for old in pendingStopAnnotations {
                map.removeAnnotation(old)
            }
            pendingStopAnnotations.removeAll(keepingCapacity: true)
            for (index, stop) in state.pendingStops.enumerated() {
                let pin = StopAnnotation(stopNumber: index + 1)
                pin.coordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lng)
                pin.title = "Stop \(index + 1)"
                pin.subtitle = String(format: "%.5f, %.5f", stop.lat, stop.lng)
                map.addAnnotation(pin)
                pendingStopAnnotations.append(pin)
            }

            // --- Simulated location (green) -----------------------------
            if let old = simulatedAnnotation {
                map.removeAnnotation(old)
                simulatedAnnotation = nil
            }
            if let sim = state.simulatedLocation {
                let pin = SimulatedAnnotation()
                pin.coordinate = CLLocationCoordinate2D(latitude: sim.lat, longitude: sim.lng)
                pin.title = "iPhone (simulated)"
                pin.subtitle = String(format: "%.5f, %.5f", sim.lat, sim.lng)
                map.addAnnotation(pin)
                simulatedAnnotation = pin
            }

            // --- Mac proxy location (blue dot) --------------------------
            // Hidden while we have a simulated location: the iPhone-
            // simulated pin is the only "current location" the user
            // should be tracking. Showing a second dot would just
            // create the visual illusion that the iPhone is in two
            // places at once.
            let macHidden = state.simulatedLocation != nil
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
                let id = "sim"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemGreen
                v.glyphImage = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
                v.canShowCallout = true
                return v

            case let stop as StopAnnotation:
                let id = "stop"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemRed
                // Numbered glyph (1-50). SF Symbols has number.circle.fill /
                // 1.circle.fill, but the simplest match is `glyphText`.
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
    init(stopNumber: Int) { self.stopNumber = stopNumber; super.init() }
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
