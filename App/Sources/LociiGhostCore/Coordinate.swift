import Foundation

/// A WGS-84 latitude/longitude pair.
///
/// Lives in LociiGhostCore rather than the app target so that the pure
/// geometry that operates on it — `StopOrdering`, and anything else
/// that follows — can be unit-tested without standing up SwiftUI or
/// SwiftData. The app adds its own MapKit conveniences as extensions.
public struct Coordinate: Hashable, Sendable, Codable {
    public let lat: Double
    public let lng: Double

    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }

    /// True when two coordinates are within ~1 cm on the ground. Used
    /// by the position-event handler to short-circuit no-op echoes the
    /// daemon emits while the device sits in simulated-location mode —
    /// every echo's coord is the spoofed target, but float noise in
    /// the device→daemon→app pipeline means exact equality fails.
    /// 1e-7 degrees ≈ 1.1 cm at the equator; well below any meaningful
    /// device motion, well above any rounding noise in a Double.
    public func isApproximately(_ other: Coordinate) -> Bool {
        abs(lat - other.lat) < 1e-7 && abs(lng - other.lng) < 1e-7
    }
}
