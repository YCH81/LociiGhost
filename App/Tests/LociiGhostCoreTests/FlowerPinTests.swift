import XCTest
@testable import LociiGhostCore

final class FlowerPinTests: XCTestCase {

    // MARK: - The catalogue is a contract

    func testThereAreExactlySixDesigns() {
        XCTAssertEqual(FlowerPin.designs.count, 6)
    }

    /// These ids are written onto bookmarks. Renaming one silently
    /// repaints every pin that used it, and a user with 3 000
    /// bookmarks has no way to undo that. Changing this list should
    /// be a decision, not a rename refactor.
    func testDesignIDsAreStable() {
        XCTAssertEqual(FlowerPin.designs.map(\.id),
                       ["daisy", "sakura", "tulip", "sunflower", "clover", "plum"])
    }

    func testDesignIDsAreUnique() {
        XCTAssertEqual(Set(FlowerPin.designs.map(\.id)).count, FlowerPin.designs.count)
    }

    func testEveryDesignIsDistinctGeometry() {
        // Six entries that render identically would be six choices
        // the user can't tell apart.
        let shapes = FlowerPin.designs.map { d in
            "\(d.petals)|\(d.petalDistance)|\(d.petalRadius)|\(d.lobes)|\(d.centreRadius)"
        }
        XCTAssertEqual(Set(shapes).count, FlowerPin.designs.count)
    }

    // MARK: - Stored form

    func testRoundTripThroughTheStoredSymbol() {
        for d in FlowerPin.designs {
            let stored = FlowerPin.storedSymbol(for: d)
            XCTAssertTrue(stored.hasPrefix("flower."))
            XCTAssertEqual(FlowerPin.design(forStoredSymbol: stored)?.id, d.id)
        }
    }

    func testAnSFSymbolNameIsNotAFlower() {
        // Pre-v1.17 bookmarks carry SF Symbol names in the same field.
        // Claiming those as flowers would repaint every existing pin.
        XCTAssertNil(FlowerPin.design(forStoredSymbol: "mappin.circle.fill"))
        XCTAssertNil(FlowerPin.design(forStoredSymbol: "star.fill"))
        XCTAssertNil(FlowerPin.design(forStoredSymbol: ""))
    }

    func testAnUnknownFlowerIDFallsBackInsteadOfDisappearing() {
        // `flower.` was clearly meant to be a flower. Showing the
        // wrong one beats a pin that renders as nothing.
        XCTAssertEqual(FlowerPin.design(forStoredSymbol: "flower.orchid")?.id,
                       FlowerPin.fallback.id)
        XCTAssertEqual(FlowerPin.design(forStoredSymbol: "flower.")?.id,
                       FlowerPin.fallback.id)
    }

    // MARK: - Geometry

    func testDiscCountMatchesPetalsAndLobes() {
        for d in FlowerPin.designs {
            let expected = d.petals * max(1, d.lobes)
            XCTAssertEqual(FlowerPin.discs(for: d).count, expected, "\(d.id)")
        }
    }

    func testEveryDiscStaysInsideTheUnitCircle() {
        // The pin is drawn in a fixed frame; a petal reaching past 1.0
        // gets clipped, which looks like a rendering bug rather than a
        // design choice.
        for d in FlowerPin.designs {
            for disc in FlowerPin.discs(for: d) {
                let reach = (disc.x * disc.x + disc.y * disc.y).squareRoot() + disc.r
                XCTAssertLessThanOrEqual(reach, 1.0001,
                                         "\(d.id) petal reaches \(reach)")
            }
        }
    }

    func testPetalsAreEvenlySpacedAroundTheCentre() {
        // A single-lobe design's petals should sit at equal angles;
        // an off-by-one in the step would bunch them to one side.
        let daisy = FlowerPin.designs.first { $0.id == "daisy" }!
        let angles = FlowerPin.discs(for: daisy)
            .map { atan2($0.y, $0.x) }
            .sorted()
        let gaps = zip(angles, angles.dropFirst()).map { $1 - $0 }
        let expected = 2 * Double.pi / Double(daisy.petals)
        for g in gaps {
            XCTAssertEqual(g, expected, accuracy: 0.0001)
        }
    }

    func testATwoLobeDesignPairsItsDiscs() {
        let sakura = FlowerPin.designs.first { $0.id == "sakura" }!
        let discs = FlowerPin.discs(for: sakura)
        XCTAssertEqual(discs.count, sakura.petals * 2)
        // Each pair sits `lobeSpread` apart, so the two discs of one
        // petal are closer to each other than a petal is to its
        // neighbour — that's what makes the tip read as notched
        // rather than as ten separate petals.
        let d0 = discs[0], d1 = discs[1], d2 = discs[2]
        let within = ((d0.x - d1.x) * (d0.x - d1.x) + (d0.y - d1.y) * (d0.y - d1.y)).squareRoot()
        let across = ((d1.x - d2.x) * (d1.x - d2.x) + (d1.y - d2.y) * (d1.y - d2.y)).squareRoot()
        XCTAssertLessThan(within, across)
    }

    func testDiscsAreProducedForEveryDesignWithoutCrashing() {
        for d in FlowerPin.designs {
            XCTAssertFalse(FlowerPin.discs(for: d).isEmpty, "\(d.id)")
        }
    }
}
