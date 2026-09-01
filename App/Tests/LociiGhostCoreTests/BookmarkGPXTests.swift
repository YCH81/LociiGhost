import XCTest
@testable import LociiGhostCore

final class BookmarkGPXTests: XCTestCase {

    private func encodeThenDecode(_ w: [BookmarkWaypoint]) throws -> [BookmarkWaypoint] {
        let xml = BookmarkGPX.encode(w)
        return try BookmarkGPX.decode(Data(xml.utf8))
    }

    // MARK: - Round trip

    func testEveryFieldSurvivesARoundTrip() throws {
        let source = [
            BookmarkWaypoint(name: "台北 101", lat: 25.033964, lng: 121.564468,
                             category: "景點", symbol: "flower.sakura",
                             colorHex: "#C2453B",
                             imageURL: "https://example.com/101.jpg"),
            BookmarkWaypoint(name: "Home", lat: -33.865143, lng: 151.209900,
                             category: "", symbol: "house.fill"),
        ]
        let back = try encodeThenDecode(source)
        XCTAssertEqual(back, source)
    }

    /// Six decimals is ~11 cm. A bookmark that moves when you export
    /// and re-import it is the one failure a user would actually
    /// notice, so the tolerance is pinned rather than left to chance.
    func testCoordinatesSurviveToSixDecimals() throws {
        let source = [BookmarkWaypoint(name: "P", lat: 24.1234564, lng: 120.6912344)]
        let back = try encodeThenDecode(source)
        XCTAssertEqual(back[0].lat, 24.123456, accuracy: 0.0000005)
        XCTAssertEqual(back[0].lng, 120.691234, accuracy: 0.0000005)
    }

    func testNamesWithMarkupSurvive() throws {
        let nasty = "A & B <tag> \"quoted\" 'single' >"
        let back = try encodeThenDecode([
            BookmarkWaypoint(name: nasty, lat: 1, lng: 2, category: nasty),
        ])
        XCTAssertEqual(back[0].name, nasty)
        XCTAssertEqual(back[0].category, nasty)
    }

    /// `&` has to be escaped before `<` and `"`, or the entities we
    /// just wrote get their own ampersand escaped a second time and
    /// the name comes back as `&amp;lt;`.
    func testAmpersandIsEscapedFirst() {
        XCTAssertEqual(BookmarkGPX.escape("<&>"), "&lt;&amp;&gt;")
    }

    // MARK: - What we deliberately don't write

    /// Derived colours are computed from the name by a hash we own, so
    /// they're already the same on every machine. Writing them would
    /// turn every derived colour into an explicit override the moment
    /// the file is imported.
    func testNoColourElementWhenTheCategoryUsesItsDerivedColour() throws {
        let xml = BookmarkGPX.encode([
            BookmarkWaypoint(name: "P", lat: 1, lng: 2, category: "Work"),
        ])
        XCTAssertFalse(xml.contains("color"))
        XCTAssertNil(try BookmarkGPX.decode(Data(xml.utf8))[0].colorHex)
    }

    func testUncategorisedWaypointOmitsTheTypeElement() throws {
        let xml = BookmarkGPX.encode([BookmarkWaypoint(name: "P", lat: 1, lng: 2)])
        XCTAssertFalse(xml.contains("<type>"))
        XCTAssertEqual(try BookmarkGPX.decode(Data(xml.utf8))[0].category, "")
    }

    func testAMalformedColourIsDroppedRatherThanStored() throws {
        let back = try encodeThenDecode([
            BookmarkWaypoint(name: "P", lat: 1, lng: 2,
                             category: "Work", colorHex: "not a colour"),
        ])
        XCTAssertNil(back[0].colorHex)
    }

    func testShorthandColourIsNormalisedOnTheWayIn() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:lociighost="\(BookmarkGPX.namespaceURI)">
          <wpt lat="1" lon="2">
            <name>P</name>
            <extensions><lociighost:color>#abc</lociighost:color></extensions>
          </wpt>
        </gpx>
        """
        XCTAssertEqual(try BookmarkGPX.decode(Data(xml.utf8))[0].colorHex, "#AABBCC")
    }

    // MARK: - Foreign files

    /// A `<wpt>` from any other app has to import as a plain,
    /// uncategorised bookmark — that's the whole reason for using the
    /// standard tags instead of putting everything in `<extensions>`.
    func testAPlainForeignWaypointImports() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SomeOtherApp"
             xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Somebody else's file</name></metadata>
          <wpt lat="24.5" lon="120.5">
            <name>Trailhead</name>
            <ele>412.0</ele>
            <sym>Flag, Blue</sym>
          </wpt>
        </gpx>
        """
        let back = try BookmarkGPX.decode(Data(xml.utf8))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].name, "Trailhead")
        XCTAssertEqual(back[0].category, "")
        XCTAssertEqual(back[0].symbol, "Flag, Blue")
        XCTAssertNil(back[0].colorHex)
    }

    /// `<metadata><name>` must not leak into the first waypoint.
    func testMetadataNameDoesNotBecomeAWaypointName() throws {
        let xml = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>File title</name></metadata>
          <wpt lat="1" lon="2"><name>Real</name></wpt>
        </gpx>
        """
        XCTAssertEqual(try BookmarkGPX.decode(Data(xml.utf8))[0].name, "Real")
    }

    /// A `<name>` some other exporter tucked inside `<extensions>` is
    /// two levels down and must not overwrite the waypoint's own.
    func testANestedNameInExtensionsIsIgnored() throws {
        let xml = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="1" lon="2">
            <name>Real</name>
            <extensions><other><name>Not this</name></other></extensions>
          </wpt>
        </gpx>
        """
        XCTAssertEqual(try BookmarkGPX.decode(Data(xml.utf8))[0].name, "Real")
    }

    /// A track is a route. Importing a 4 000-point track as 4 000
    /// bookmarks is never what anyone meant, so trkpt/rtept are the
    /// route importer's job, not this one's.
    func testTrackPointsAreNotImportedAsBookmarks() throws {
        let xml = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="1" lon="2"><name>Pin</name></wpt>
          <trk><trkseg>
            <trkpt lat="3" lon="4"/><trkpt lat="5" lon="6"/>
          </trkseg></trk>
          <rte><rtept lat="7" lon="8"/></rte>
        </gpx>
        """
        let back = try BookmarkGPX.decode(Data(xml.utf8))
        XCTAssertEqual(back.map(\.name), ["Pin"])
    }

    func testLinkHrefBecomesTheImageURL() throws {
        let xml = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="1" lon="2">
            <name>P</name>
            <link href="https://example.com/a.jpg"><text>photo</text></link>
          </wpt>
        </gpx>
        """
        let back = try BookmarkGPX.decode(Data(xml.utf8))
        XCTAssertEqual(back[0].imageURL, "https://example.com/a.jpg")
        // The <text> label is not the target and must not land in a field.
        XCTAssertEqual(back[0].name, "P")
    }

    // MARK: - Bad input

    func testOutOfRangeCoordinatesAreSkipped() throws {
        let xml = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="91" lon="2"><name>Off the planet</name></wpt>
          <wpt lat="1" lon="181"><name>Also</name></wpt>
          <wpt lat="1" lon="2"><name>Fine</name></wpt>
        </gpx>
        """
        XCTAssertEqual(try BookmarkGPX.decode(Data(xml.utf8)).map(\.name), ["Fine"])
    }

    func testMalformedXMLThrowsUnparseable() {
        XCTAssertThrowsError(try BookmarkGPX.decode(Data("<gpx><wpt".utf8))) { error in
            guard case BookmarkGPXError.unparseable = error else {
                return XCTFail("expected .unparseable, got \(error)")
            }
        }
    }

    func testAValidFileWithNoWaypointsThrowsEmpty() {
        let xml = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Nothing here</name></metadata>
        </gpx>
        """
        XCTAssertThrowsError(try BookmarkGPX.decode(Data(xml.utf8))) { error in
            XCTAssertEqual(error as? BookmarkGPXError, .empty)
        }
    }

    func testEncodingEmptyInputStillProducesAValidDocument() {
        let xml = BookmarkGPX.encode([])
        XCTAssertTrue(xml.contains("<gpx"))
        XCTAssertTrue(xml.hasSuffix("</gpx>"))
        XCTAssertThrowsError(try BookmarkGPX.decode(Data(xml.utf8)))
    }
}
