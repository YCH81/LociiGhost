import XCTest
@testable import LociiGhostCore

final class GeocodingTests: XCTestCase {

    // MARK: - URLs

    func testNominatimURLCarriesTheQueryAndFormat() throws {
        let url = try XCTUnwrap(OSMGeocoding.nominatimURL(
            query: "台北 101", limit: 5, language: "zh-TW"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["q"], "台北 101")
        // jsonv2 is what splits `name` out of `display_name`; without
        // it every row's title is the whole address.
        XCTAssertEqual(byName["format"], "jsonv2")
        XCTAssertEqual(byName["limit"], "5")
        XCTAssertEqual(byName["accept-language"], "zh-TW")
        XCTAssertEqual(url.host, "nominatim.openstreetmap.org")
    }

    /// The query goes through URLComponents, so a `&` in a place name
    /// must not start a new parameter.
    func testAQueryWithURLSyntaxIsEscaped() throws {
        let url = try XCTUnwrap(OSMGeocoding.nominatimURL(
            query: "A&W #3 100%", language: "en"))
        XCTAssertFalse(url.absoluteString.contains("A&W"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "A&W #3 100%")
    }

    func testAnEmptyQueryProducesNoURL() {
        XCTAssertNil(OSMGeocoding.nominatimURL(query: "   ", language: "en"))
        XCTAssertNil(OSMGeocoding.photonURL(query: "", language: "en"))
    }

    /// Photon 400s on a language it doesn't know, so a full locale
    /// identifier has to be cut down before it goes out.
    func testPhotonLanguageFallsBackToEnglish() {
        XCTAssertEqual(OSMGeocoding.photonLanguage("zh-Hant-TW"), "en")
        XCTAssertEqual(OSMGeocoding.photonLanguage("de_DE"), "de")
        XCTAssertEqual(OSMGeocoding.photonLanguage("FR"), "fr")
        XCTAssertEqual(OSMGeocoding.photonLanguage(""), "en")
    }

    // MARK: - Nominatim decoding

    private let nominatimJSON = """
    [
      {
        "place_id": 297963686,
        "osm_type": "way",
        "osm_id": 168637428,
        "lat": "25.0339639",
        "lon": "121.5644722",
        "name": "台北101",
        "display_name": "台北101, 5, 信義路五段, 信義區, 臺北市, 110, 臺灣"
      },
      {
        "place_id": 12,
        "osm_id": 34,
        "lat": "24.1477",
        "lon": "120.6736",
        "name": "",
        "display_name": "1號, 台灣大道, 中區, 臺中市, 臺灣"
      }
    ]
    """

    func testNominatimDecodesNameAndAddressSeparately() throws {
        let hits = try OSMGeocoding.decodeNominatim(Data(nominatimJSON.utf8))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].title, "台北101")
        XCTAssertTrue(hits[0].subtitle.hasPrefix("台北101, 5, 信義路五段"))
        XCTAssertEqual(hits[0].coordinate.lat, 25.0339639, accuracy: 1e-7)
        XCTAssertEqual(hits[0].coordinate.lng, 121.5644722, accuracy: 1e-7)
        XCTAssertEqual(hits[0].id, "nominatim-297963686")
    }

    /// A plain address has no `name`, and a row with an empty first
    /// line looks broken, so the first component of the address is
    /// promoted instead.
    func testANamelessNominatimResultPromotesItsFirstAddressComponent() throws {
        let hits = try OSMGeocoding.decodeNominatim(Data(nominatimJSON.utf8))
        XCTAssertEqual(hits[1].title, "1號")
    }

    /// Nominatim sends coordinates as strings. A build that stops
    /// parsing them would silently return zero hits for every query.
    func testNominatimStringCoordinatesThatDontParseAreDropped() throws {
        let json = """
        [{"place_id":1,"lat":"north","lon":"121.5","display_name":"X"},
         {"place_id":2,"lat":"25.0","lon":"121.5","display_name":"Y"}]
        """
        let hits = try OSMGeocoding.decodeNominatim(Data(json.utf8))
        XCTAssertEqual(hits.map(\.title), ["Y"])
    }

    func testNominatimOutOfRangeCoordinatesAreDropped() throws {
        let json = """
        [{"place_id":1,"lat":"95.0","lon":"121.5","display_name":"Off the planet"},
         {"place_id":2,"lat":"25.0","lon":"121.5","display_name":"Fine"}]
        """
        let hits = try OSMGeocoding.decodeNominatim(Data(json.utf8))
        XCTAssertEqual(hits.map(\.title), ["Fine"])
    }

    func testMalformedNominatimPayloadThrowsDecode() {
        XCTAssertThrowsError(try OSMGeocoding.decodeNominatim(Data("{}".utf8))) {
            XCTAssertEqual($0 as? GeocodeError, .decode)
        }
    }

    // MARK: - Photon decoding

    private let photonJSON = """
    {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "geometry": { "type": "Point", "coordinates": [121.5645, 25.0340] },
          "properties": {
            "osm_id": 168637428, "osm_type": "W",
            "name": "Taipei 101", "street": "Xinyi Road Section 5",
            "housenumber": "7", "city": "Taipei", "state": "Taipei",
            "country": "Taiwan", "postcode": "110"
          }
        },
        {
          "type": "Feature",
          "geometry": { "type": "Point", "coordinates": [120.6736, 24.1477] },
          "properties": {
            "osm_id": 99, "osm_type": "N",
            "street": "Taiwan Boulevard", "city": "Taichung", "country": "Taiwan"
          }
        }
      ]
    }
    """

    /// GeoJSON is [longitude, latitude]. Reading it the other way puts
    /// Taipei in the Indian Ocean and every result is plausible-looking
    /// nonsense, so this is pinned.
    func testPhotonCoordinatesAreLonLat() throws {
        let hits = try OSMGeocoding.decodePhoton(Data(photonJSON.utf8))
        XCTAssertEqual(hits[0].coordinate.lat, 25.0340, accuracy: 1e-6)
        XCTAssertEqual(hits[0].coordinate.lng, 121.5645, accuracy: 1e-6)
    }

    func testPhotonNamedPlaceKeepsItsNameAsTheTitle() throws {
        let hits = try OSMGeocoding.decodePhoton(Data(photonJSON.utf8))
        XCTAssertEqual(hits[0].title, "Taipei 101")
        XCTAssertEqual(hits[0].subtitle,
                       "Xinyi Road Section 5 7, Taipei, Taipei, Taiwan")
        XCTAssertEqual(hits[0].id, "photon-W168637428")
    }

    func testAPhotonResultWithNoNamePromotesItsStreet() throws {
        let hits = try OSMGeocoding.decodePhoton(Data(photonJSON.utf8))
        XCTAssertEqual(hits[1].title, "Taiwan Boulevard")
        // …and the promoted line is not repeated underneath it.
        XCTAssertEqual(hits[1].subtitle, "Taichung, Taiwan")
    }

    func testPhotonFeatureWithTruncatedCoordinatesIsDropped() throws {
        let json = """
        {"features":[
          {"geometry":{"coordinates":[121.5]},"properties":{"name":"Half"}},
          {"geometry":{"coordinates":[121.5,25.0]},"properties":{"name":"Whole"}}
        ]}
        """
        let hits = try OSMGeocoding.decodePhoton(Data(json.utf8))
        XCTAssertEqual(hits.map(\.title), ["Whole"])
    }

    func testEmptyPhotonCollectionIsNotAnError() throws {
        XCTAssertEqual(try OSMGeocoding.decodePhoton(Data("{\"features\":[]}".utf8)), [])
    }

    // MARK: - Provider metadata

    /// Nominatim's usage policy caps one source at one request per
    /// second. This isn't a performance tuning knob — going faster is
    /// how the app gets blocked from the service.
    func testNominatimIsRateLimitedToAboutOneRequestPerSecond() {
        XCTAssertGreaterThanOrEqual(
            GeocodeProvider.nominatim.minimumRequestInterval, .seconds(1))
    }

    /// ODbL requires attribution for the OSM-derived services.
    func testTheOpenStreetMapProvidersCarryAttribution() {
        XCTAssertNotNil(GeocodeProvider.nominatim.attribution)
        XCTAssertNotNil(GeocodeProvider.photon.attribution)
        XCTAssertNil(GeocodeProvider.apple.attribution)
    }

    func testOnlyGoogleNeedsAKey() {
        XCTAssertEqual(GeocodeProvider.allCases.filter(\.needsAPIKey), [.google])
    }

    /// The raw values are persisted in preferences; renaming one
    /// silently resets every user's choice to the default.
    func testProviderRawValuesAreStable() {
        XCTAssertEqual(GeocodeProvider.allCases.map(\.rawValue),
                       ["apple", "nominatim", "photon", "google"])
    }

    func testTheUserAgentIdentifiesTheApp() {
        XCTAssertTrue(OSMGeocoding.userAgent(version: "1.17.0").hasPrefix("LociiGhost/1.17.0"))
    }
}
