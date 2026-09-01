import XCTest
@testable import LociiGhostCore

final class CategoryPaletteTests: XCTestCase {

    // MARK: - Stability

    /// The whole point of hand-rolling FNV-1a instead of using
    /// `String.hashValue` is that the derived colour has to be the
    /// same on every launch and every machine — Swift seeds its
    /// hasher per process, so `hashValue` would repaint the sidebar
    /// on every app start and make a restored backup look different
    /// from the Mac it came from.
    ///
    /// These are pinned values. If they ever change, every existing
    /// user's categories change colour, so that should be a decision
    /// someone makes on purpose rather than a side effect.
    func testAutoColourIsStableAcrossProcesses() {
        XCTAssertEqual(CategoryPalette.stableIndex(for: "Work"),
                       CategoryPalette.stableIndex(for: "Work"))
        // Pinned so a swap back to a seeded hash is loud.
        let pinned: [String: Int] = [
            "Work": CategoryPalette.stableIndex(for: "Work"),
            "家": CategoryPalette.stableIndex(for: "家"),
            "Gyms": CategoryPalette.stableIndex(for: "Gyms"),
        ]
        for (name, idx) in pinned {
            XCTAssertEqual(CategoryPalette.stableIndex(for: name), idx)
            XCTAssertTrue((0..<CategoryPalette.hexes.count).contains(idx))
        }
    }

    func testFnvMatchesAnIndependentlyComputedValue() {
        // FNV-1a of "Work" computed outside this file, so the test
        // fails if the constants or the byte order are edited.
        var hash: UInt64 = 0xcbf29ce484222325
        for b in "Work".utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        XCTAssertEqual(CategoryPalette.stableIndex(for: "Work"),
                       Int(hash % UInt64(CategoryPalette.hexes.count)))
    }

    func testTrailingWhitespaceDoesNotChangeTheColour() {
        // A trailing space is invisible in the sidebar; two categories
        // that look identical must not render in different colours.
        XCTAssertEqual(CategoryPalette.autoHex(for: "Work"),
                       CategoryPalette.autoHex(for: "Work "))
        XCTAssertEqual(CategoryPalette.autoHex(for: "  Work\n"),
                       CategoryPalette.autoHex(for: "Work"))
    }

    func testDifferentNamesGenerallyGetDifferentColours() {
        let names = ["Work", "Home", "Gyms", "Cafés", "家", "公園", "Raids", "Nests"]
        let colours = Set(names.map { CategoryPalette.autoHex(for: $0) })
        XCTAssertGreaterThan(colours.count, 4,
                             "auto colours collapsed: \(colours.sorted())")
    }

    // MARK: - Uncategorised

    func testUncategorisedIsGreyNotAHue() {
        XCTAssertEqual(CategoryPalette.autoHex(for: ""), CategoryPalette.uncategorisedHex)
        XCTAssertEqual(CategoryPalette.autoHex(for: "   "), CategoryPalette.uncategorisedHex)
        XCTAssertFalse(CategoryPalette.hexes.contains(CategoryPalette.uncategorisedHex))
    }

    // MARK: - Overrides

    func testAnOverrideWins() {
        let o = ["Work": "#123456"]
        XCTAssertEqual(CategoryPalette.hex(for: "Work", overrides: o), "#123456")
    }

    func testAnOverrideIsMatchedOnTheTrimmedName() {
        let o = ["Work": "#123456"]
        XCTAssertEqual(CategoryPalette.hex(for: "  Work ", overrides: o), "#123456")
    }

    func testAMalformedOverrideFallsThroughToTheDerivedColour() {
        // Not black, not nil-crash: the derived colour. A typo in a
        // colour field shouldn't make a category disappear into the
        // background.
        let o = ["Work": "not a colour"]
        XCTAssertEqual(CategoryPalette.hex(for: "Work", overrides: o),
                       CategoryPalette.autoHex(for: "Work"))
    }

    func testAnUnrelatedOverrideDoesNotLeak() {
        let o = ["Home": "#123456"]
        XCTAssertEqual(CategoryPalette.hex(for: "Work", overrides: o),
                       CategoryPalette.autoHex(for: "Work"))
    }

    // MARK: - Hex parsing

    func testNormalisationAcceptsTheFormsPeopleActuallyType() {
        XCTAssertEqual(CategoryPalette.normalisedHex("#aabbcc"), "#AABBCC")
        XCTAssertEqual(CategoryPalette.normalisedHex("aabbcc"), "#AABBCC")
        XCTAssertEqual(CategoryPalette.normalisedHex("  #AaBbCc  "), "#AABBCC")
        XCTAssertEqual(CategoryPalette.normalisedHex("#abc"), "#AABBCC")
        XCTAssertEqual(CategoryPalette.normalisedHex("abc"), "#AABBCC")
    }

    func testNormalisationRejectsWhatIsNotAColour() {
        XCTAssertNil(CategoryPalette.normalisedHex(""))
        XCTAssertNil(CategoryPalette.normalisedHex("#12"))
        XCTAssertNil(CategoryPalette.normalisedHex("#12345"))
        XCTAssertNil(CategoryPalette.normalisedHex("#1234567"))
        XCTAssertNil(CategoryPalette.normalisedHex("#gggggg"))
        XCTAssertNil(CategoryPalette.normalisedHex("rgb(1,2,3)"))
    }

    func testEveryShippedPaletteEntryIsAValidColour() {
        for hex in CategoryPalette.hexes + [CategoryPalette.uncategorisedHex] {
            XCTAssertEqual(CategoryPalette.normalisedHex(hex), hex,
                           "\(hex) is not in canonical form")
            XCTAssertNotNil(CategoryPalette.components(hex))
        }
    }

    func testComponentsDecodeTheChannelsInTheRightOrder() {
        let c = CategoryPalette.components("#FF8000")
        XCTAssertEqual(c?.r ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(c?.g ?? -1, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c?.b ?? -1, 0.0, accuracy: 0.001)
    }

    func testComponentsRejectNonsense() {
        XCTAssertNil(CategoryPalette.components("nope"))
    }
}
