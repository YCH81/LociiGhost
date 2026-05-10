import CoreLocation
import Foundation
import Observation

/// Reads the **Mac's** location via CoreLocation as a stand-in for the
/// iPhone's real GPS.
///
/// We can't read the connected iPhone's CoreLocation from macOS — Apple
/// doesn't expose it over the DVT/RSD developer tunnel. The Mac is almost
/// always within USB reach of the phone, so its location is a pragmatic
/// approximation while no simulation is active.
///
/// Idle-friendly: we ask the OS for ONE fix and immediately stop updates.
/// No continuous polling, no GPS-radio churn. The user can request a fresh
/// fix on demand via `refresh()`.
@MainActor
@Observable
final class LocationProxyService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    /// Most recent fix from CoreLocation. `nil` if we haven't been granted
    /// permission, or if a fix hasn't arrived yet.
    var coordinate: CLLocationCoordinate2D?
    /// Horizontal accuracy in metres of `coordinate`, if known.
    var accuracy: Double?
    /// When `coordinate` was last updated.
    var lastFixAt: Date?
    /// Current CLLocationManager authorisation state.
    var status: CLAuthorizationStatus

    override init() {
        self.status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters    // city-level is enough; saves power
    }

    /// Show the system permission prompt if we haven't asked yet, then
    /// kick a single location fix.
    func requestPermissionAndFetch() {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            // The app can't reopen the prompt; user has to flip the switch
            // in System Settings → Privacy & Security → Location Services.
            return
        @unknown default:
            return
        }
    }

    /// Force a fresh single-shot fix even if we already have one.
    func refresh() {
        guard status == .authorized || status == .authorizedAlways else {
            requestPermissionAndFetch()
            return
        }
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Snapshot the value-typed status before hopping actors so the
        // CLLocationManager itself never crosses the isolation boundary.
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.status = newStatus
            if newStatus == .authorized || newStatus == .authorizedAlways {
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coord = last.coordinate
        let acc = last.horizontalAccuracy
        Task { @MainActor in
            self.coordinate = coord
            self.accuracy = acc
            self.lastFixAt = Date()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Most errors here are transient (radio not warmed up, indoor with no
        // WiFi). We don't surface them — the UI just keeps the previous fix
        // and the user can hit Refresh to retry.
    }
}
