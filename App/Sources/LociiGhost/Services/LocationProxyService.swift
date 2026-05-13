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

    /// Continuations waiting for the next `didUpdateLocations` callback.
    /// Keyed by UUID so the timeout side of `fetchFreshFix` can resume
    /// only the entry it owns without disturbing other concurrent waiters.
    /// Drained on every successful fix.
    private var fixWaiters: [UUID: CheckedContinuation<CLLocationCoordinate2D?, Never>] = [:]

    /// Request a fresh fix and `await` until either a new one lands or
    /// `timeout` elapses. Returns the coordinate on success, `nil` if
    /// the timeout fired, the user denied permission, or the system has
    /// yet to determine authorisation. Safe to call concurrently — every
    /// waiter receives the same next fix.
    ///
    /// Existing fix in `coordinate` is intentionally ignored: callers
    /// who want "use what we already have, then refresh in the
    /// background" can read `coordinate` and call `refresh()` directly.
    /// This method exists for the opposite case — caller needs the
    /// answer to be fresh before proceeding (e.g. Restore-Real-GPS,
    /// which flies the map to the user's *current* location).
    func fetchFreshFix(timeout: TimeInterval) async -> CLLocationCoordinate2D? {
        guard status == .authorized || status == .authorizedAlways else {
            // Either user hasn't decided yet or they denied. Surface
            // the prompt if undetermined; either way bail so the caller
            // can show a "needs permission" message rather than hanging
            // for the full timeout window.
            requestPermissionAndFetch()
            return nil
        }
        manager.requestLocation()
        let myId = UUID()
        return await withCheckedContinuation { cont in
            fixWaiters[myId] = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                if let pending = self.fixWaiters.removeValue(forKey: myId) {
                    pending.resume(returning: nil)
                }
            }
        }
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
            // Drain anyone awaiting `fetchFreshFix`. Snapshot the dict
            // before resuming so a continuation that synchronously
            // chains another fetchFreshFix() during its resume doesn't
            // see itself in the queue.
            let waiters = self.fixWaiters
            self.fixWaiters.removeAll()
            for (_, cont) in waiters {
                cont.resume(returning: coord)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Most errors here are transient (radio not warmed up, indoor with no
        // WiFi). We don't surface them — the UI just keeps the previous fix
        // and the user can hit Refresh to retry.
    }
}
