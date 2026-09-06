import Foundation

/// Spherical-earth geometry shared by the two map layers.
///
/// The flat-earth shortcut — metres ÷ 111 320, longitude ÷ cos(lat) —
/// is deliberately absent. At 70°N it puts a 100 m ring 17 cm out of
/// round, and that same approximation is what turns a stack of flower
/// laps into a slow spiral. The daemon's `flower_plan` already uses
/// the spherical formula; this is its Swift counterpart so the ring
/// the user sees and the ring the iPhone walks are the same circle.
public enum Geodesy {
    /// Mean earth radius, matching `StopOrdering.haversineMeters`.
    public static let earthRadiusM = 6_371_000.0

    /// The point `distanceM` from `origin` along `bearingDegrees`
    /// (0 = north, 90 = east), on a sphere.
    public static func destination(from origin: Coordinate,
                                   bearingDegrees: Double,
                                   distanceM: Double) -> Coordinate {
        let angular = distanceM / earthRadiusM
        let bearing = bearingDegrees * .pi / 180
        let lat1 = origin.lat * .pi / 180
        let lng1 = origin.lng * .pi / 180

        // Clamp before asin: accumulated rounding can push the sine a
        // hair past ±1 for antipodal-ish inputs, and asin(1.0000001)
        // is NaN, which silently poisons every coordinate downstream.
        let sinLat2 = sin(lat1) * cos(angular)
                    + cos(lat1) * sin(angular) * cos(bearing)
        let lat2 = asin(min(1, max(-1, sinLat2)))
        let lng2 = lng1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sinLat2)

        // Normalise into −180…180 so MapKit gets a longitude it can
        // place without wrapping the annotation to the far side of
        // the world near the antimeridian.
        var lng = (lng2 * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if lng > 180 { lng -= 360 }
        if lng < -180 { lng += 360 }
        return Coordinate(lat: lat2 * 180 / .pi, lng: lng)
    }
}
