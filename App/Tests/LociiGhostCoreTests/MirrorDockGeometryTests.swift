import XCTest
@testable import LociiGhostCore

/// The docked-mirror layout is arithmetic wrapped around a
/// coordinate-system flip, run against whatever multi-display setup
/// the user happens to have. That's exactly the shape of code that
/// looks obviously right and is wrong on the second monitor, so the
/// arithmetic lives in `MirrorDockGeometry` where it can be pinned
/// down without a window server.
final class MirrorDockGeometryTests: XCTestCase {

    /// A 1512x900 built-in display, menu bar excluded — AX space, so
    /// the origin is the top-left corner and y grows downward.
    private let screen = CGRect(x: 0, y: 25, width: 1512, height: 875)

    private let phone = CGSize(width: 320, height: 690)

    // MARK: - The common case

    func testDocksFlushToTheRightWithoutMovingTheApp() {
        let app = CGRect(x: 40, y: 60, width: 1000, height: 700)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .right, gap: 8,
        )
        XCTAssertTrue(p.fits)
        XCTAssertNil(p.appOrigin, "app window should stay where the user put it")
        XCTAssertEqual(p.mirrorOrigin.x, 1048, accuracy: 0.001)  // 40 + 1000 + 8
        XCTAssertEqual(p.mirrorOrigin.y, 60, accuracy: 0.001)    // top-aligned
    }

    func testDocksFlushToTheLeft() {
        let app = CGRect(x: 500, y: 60, width: 900, height: 700)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .left, gap: 8,
        )
        XCTAssertTrue(p.fits)
        XCTAssertNil(p.appOrigin)
        XCTAssertEqual(p.mirrorOrigin.x, 172, accuracy: 0.001)   // 500 - 8 - 320
    }

    // MARK: - Making room

    func testSlidesTheAppLeftWhenTheMirrorWouldFallOffTheRightEdge() {
        // App is 1000 wide starting at x=400: its right edge is 1400,
        // so the phone would end at 1728 — 216pt past the screen.
        let app = CGRect(x: 400, y: 60, width: 1000, height: 700)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .right, gap: 8,
        )
        XCTAssertTrue(p.fits)
        XCTAssertEqual(p.appOrigin?.x ?? .nan, 184, accuracy: 0.001)  // 400 - 216
        XCTAssertEqual(p.appOrigin?.y ?? .nan, 60, accuracy: 0.001,
                       "sliding sideways must not change the vertical position")
        XCTAssertEqual(p.mirrorOrigin.x, 1192, accuracy: 0.001)       // 184+1000+8
        XCTAssertEqual(p.mirrorOrigin.x + phone.width, screen.maxX, accuracy: 0.001,
                       "the pair should end exactly at the screen edge")
    }

    func testSlidesTheAppRightWhenDockingLeftWouldFallOffTheLeftEdge() {
        let app = CGRect(x: 100, y: 60, width: 1000, height: 700)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .left, gap: 8,
        )
        XCTAssertTrue(p.fits)
        XCTAssertEqual(p.appOrigin?.x ?? .nan, 328, accuracy: 0.001)  // 8 + 320
        XCTAssertEqual(p.mirrorOrigin.x, 0, accuracy: 0.001)
    }

    /// Regression guard for the obvious bug: clamping the app to the
    /// screen edge but then computing the mirror from the *old* app
    /// position, which leaves a gap or an overlap.
    func testMirrorIsComputedFromTheMovedAppPosition() {
        let app = CGRect(x: 1200, y: 60, width: 300, height: 700)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .right, gap: 8,
        )
        let appX = p.appOrigin?.x ?? app.minX
        XCTAssertEqual(p.mirrorOrigin.x, appX + app.width + 8, accuracy: 0.001)
    }

    // MARK: - Doesn't fit

    func testReportsNoFitWhenThePairIsWiderThanTheScreen() {
        let app = CGRect(x: 0, y: 60, width: 1400, height: 700)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .right, gap: 8,
        )
        XCTAssertFalse(p.fits)
        XCTAssertNil(p.appOrigin, "don't shove the user's window around in a layout we can't satisfy")
        // Still reachable rather than parked off-screen.
        XCTAssertGreaterThanOrEqual(p.mirrorOrigin.x, screen.minX)
        XCTAssertLessThanOrEqual(p.mirrorOrigin.x + phone.width, screen.maxX + 0.001)
    }

    // MARK: - Vertical

    func testMirrorNeverRunsUnderTheMenuBar() {
        let app = CGRect(x: 40, y: 25, width: 1000, height: 700)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .right, gap: 8,
        )
        XCTAssertGreaterThanOrEqual(p.mirrorOrigin.y, screen.minY)
    }

    func testMirrorIsPushedUpWhenTopAligningWouldRunPastTheBottom() {
        let app = CGRect(x: 40, y: 700, width: 1000, height: 180)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: screen, edge: .right, gap: 8,
        )
        XCTAssertEqual(p.mirrorOrigin.y + phone.height, screen.maxY, accuracy: 0.001)
    }

    func testAMirrorTallerThanTheScreenPinsToTheTop() {
        let tall = CGSize(width: 320, height: 1200)
        let app = CGRect(x: 40, y: 400, width: 1000, height: 300)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: tall, screen: screen, edge: .right, gap: 8,
        )
        XCTAssertEqual(p.mirrorOrigin.y, screen.minY, accuracy: 0.001)
    }

    /// A display sitting above-left of the built-in one gives the
    /// screen rect a negative origin in AX space. Nothing in the
    /// placement may assume the screen starts at zero.
    func testWorksOnADisplayWithANegativeOrigin() {
        let secondary = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let app = CGRect(x: -1800, y: -200, width: 900, height: 800)
        let p = MirrorDockGeometry.place(
            app: app, mirrorSize: phone, screen: secondary, edge: .right, gap: 8,
        )
        XCTAssertTrue(p.fits)
        XCTAssertNil(p.appOrigin)
        XCTAssertEqual(p.mirrorOrigin.x, -892, accuracy: 0.001)  // -1800 + 900 + 8
        XCTAssertEqual(p.mirrorOrigin.y, -200, accuracy: 0.001)
    }

    // MARK: - Aspect fitting

    func testAspectFitPreservesTheRatio() {
        let fitted = MirrorDockGeometry.aspectFittedSize(
            current: CGSize(width: 320, height: 690),
            targetHeight: 345,
            maxHeight: 875,
        )
        XCTAssertEqual(fitted?.height ?? .nan, 345, accuracy: 0.001)
        XCTAssertEqual(fitted?.width ?? .nan, 160, accuracy: 1.0)
    }

    func testAspectFitIsCappedByTheScreenHeight() {
        let fitted = MirrorDockGeometry.aspectFittedSize(
            current: CGSize(width: 320, height: 690),
            targetHeight: 2000,
            maxHeight: 875,
        )
        XCTAssertEqual(fitted?.height ?? .nan, 875, accuracy: 0.001)
    }

    func testAspectFitRefusesDegenerateInput() {
        XCTAssertNil(MirrorDockGeometry.aspectFittedSize(
            current: .zero, targetHeight: 600, maxHeight: 875,
        ))
        XCTAssertNil(MirrorDockGeometry.aspectFittedSize(
            current: CGSize(width: 320, height: 690), targetHeight: 0, maxHeight: 875,
        ))
    }
}
