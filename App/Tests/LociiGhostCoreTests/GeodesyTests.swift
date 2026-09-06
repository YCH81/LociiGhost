import XCTest
@testable import LociiGhostCore

final class GeodesyTests: XCTestCase {

    /// The whole point of the type: go out `d` metres, and haversine
    /// agrees you went `d` metres. Guards against a bad radius or a
    /// degrees/radians slip, which a "looks about right on the map"
    /// check would never catch.
    func testRoundTripsThroughHaversine() {
        let origin = Coordinate(lat: 25.0337, lng: 121.5450)   // Taipei
        for distance in [5.0, 70.0, 300.0, 5_000.0] {
            for bearing in stride(from: 0.0, to: 360.0, by: 30.0) {
                let p = Geodesy.destination(from: origin,
                                            bearingDegrees: bearing,
                                            distanceM: distance)
                let measured = StopOrdering.haversineMeters(origin, p)
                XCTAssertEqual(measured, distance, accuracy: distance * 1e-6,
                               "bearing \(bearing), distance \(distance)")
            }
        }
    }

    /// Due east stays on the parallel to well under a millimetre —
    /// this is the placement the map layers use for the radius label.
    ///
    /// Not *exactly* on it, and that is correct rather than sloppy: a
    /// great circle leaving on bearing 90° is not a rhumb line, so it
    /// creeps off the parallel as it goes. Over a 70 m ring radius the
    /// creep is ~2e-9°, about 0.2 mm. The tolerance below is 1e-6°
    /// (~11 cm) — tight enough to catch a real formula error, loose
    /// enough not to assert something spherical geometry never
    /// promised.
    func testDueEastStaysOnTheParallel() {
        let origin = Coordinate(lat: 25.0337, lng: 121.5450)
        let p = Geodesy.destination(from: origin, bearingDegrees: 90, distanceM: 70)
        XCTAssertEqual(p.lat, origin.lat, accuracy: 1e-6)
        XCTAssertGreaterThan(p.lng, origin.lng)
    }

    /// High latitude is where the flat-earth shortcut breaks down, so
    /// it is exactly where the real formula has to hold.
    func testHoldsAtHighLatitude() {
        let origin = Coordinate(lat: 70.0, lng: 25.0)
        let p = Geodesy.destination(from: origin, bearingDegrees: 90, distanceM: 100)
        XCTAssertEqual(StopOrdering.haversineMeters(origin, p), 100, accuracy: 1e-4)

        // The naive metres/(111320·cos φ) conversion lands measurably
        // short here; assert we did NOT produce that answer.
        let naiveLng = origin.lng + 100 / (111_320 * cos(origin.lat * .pi / 180))
        XCTAssertNotEqual(p.lng, naiveLng, accuracy: 1e-12)
    }

    /// Crossing the antimeridian must wrap, not run off to ±181.
    func testWrapsAcrossAntimeridian() {
        let origin = Coordinate(lat: 0, lng: 179.9999)
        let p = Geodesy.destination(from: origin, bearingDegrees: 90, distanceM: 1_000)
        XCTAssertLessThanOrEqual(p.lng, 180)
        XCTAssertGreaterThanOrEqual(p.lng, -180)
        XCTAssertLessThan(p.lng, 0, "should have wrapped to the western hemisphere")
    }

    /// Zero distance is the identity, not a NaN.
    func testZeroDistanceIsIdentity() {
        let origin = Coordinate(lat: 25.0337, lng: 121.5450)
        let p = Geodesy.destination(from: origin, bearingDegrees: 137, distanceM: 0)
        XCTAssertEqual(p.lat, origin.lat, accuracy: 1e-12)
        XCTAssertEqual(p.lng, origin.lng, accuracy: 1e-12)
    }
}
