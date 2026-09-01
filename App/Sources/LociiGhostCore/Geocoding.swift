import Foundation

/// One search result, whichever service produced it.
///
/// Two lines because that is what the dropdown draws: `title` is what
/// the place is called, `subtitle` is where it is. Providers disagree
/// about which of their fields is which, and reconciling that here —
/// once, in a testable place — is most of what this file is for.
public struct GeocodeHit: Sendable, Equatable, Identifiable {
    /// Stable within one result set. Provider-prefixed so two
    /// providers' ids can never collide in a SwiftUI `ForEach`.
    public let id: String
    public let title: String
    public let subtitle: String
    public let coordinate: Coordinate

    public init(id: String, title: String, subtitle: String, coordinate: Coordinate) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
    }
}

/// Where address search gets its answers.
///
/// Four, because no single one is right everywhere: Apple is the only
/// one with real as-you-type completion and no quota, but it indexes
/// Chinese shop and landmark names poorly; the two OpenStreetMap
/// services cover exactly the places Apple misses and cost nothing;
/// Google is the most accurate of the four for Taiwanese addresses but
/// needs the user's own billable key.
public enum GeocodeProvider: String, Sendable, CaseIterable, Codable, Identifiable {
    case apple
    case nominatim
    case photon
    case google

    public var id: String { rawValue }

    /// Non-localised name. The UI localises from the raw value.
    public var displayName: String {
        switch self {
        case .apple:     return "Apple Maps"
        case .nominatim: return "Nominatim (OpenStreetMap)"
        case .photon:    return "Photon (komoot)"
        case .google:    return "Google"
        }
    }

    /// Only Google needs one. A provider the user can't actually use
    /// is shown disabled rather than hidden, so "why is Google not in
    /// the list" never becomes a question.
    public var needsAPIKey: Bool { self == .google }

    /// Shown under the picker. The OSM services *require* attribution
    /// under ODbL; this is not decoration.
    public var attribution: String? {
        switch self {
        case .apple, .google: return nil
        case .nominatim, .photon: return "© OpenStreetMap contributors"
        }
    }

    /// Shortest gap between two requests this provider will tolerate.
    ///
    /// Nominatim's usage policy is an absolute maximum of 1 request
    /// per second from one source, and it bans "auto-complete search"
    /// against the public endpoint outright unless requests are held
    /// back until the user pauses. So the debounce is not a
    /// performance tweak here — it is the difference between using the
    /// service and being blocked from it. Photon exists precisely to
    /// serve autocomplete and is happy with far less.
    public var minimumRequestInterval: Duration {
        switch self {
        case .apple:     return .milliseconds(250)
        case .nominatim: return .milliseconds(1100)
        case .photon:    return .milliseconds(400)
        case .google:    return .milliseconds(600)
        }
    }
}

public enum GeocodeError: Error, Equatable {
    case http(Int)
    case decode
    case missingKey
    case badQuery
}

/// URL construction and response decoding for the two OpenStreetMap
/// services.
///
/// The network call itself lives in the app target; everything that
/// can be wrong without a network — which field is the name, what a
/// missing house number does to the address line, whether a string
/// latitude parses — is here, where a test can hold a real captured
/// response and assert on it.
public enum OSMGeocoding {

    /// Both services are public instances run on donated hardware.
    /// Their operators ask that clients identify themselves so abuse
    /// can be traced to an app rather than to "some Mac"; sending a
    /// generic URLSession agent is how an app gets a whole ISP
    /// blocked.
    public static func userAgent(version: String) -> String {
        "LociiGhost/\(version) (macOS; +https://github.com/lociighost)"
    }

    // MARK: - Nominatim

    public static func nominatimURL(
        query: String,
        limit: Int = 8,
        language: String,
    ) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var comps = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            // jsonv2 is the only format that returns `name` split out
            // from `display_name`; without it every row's title would
            // be the full comma-separated address.
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
            URLQueryItem(name: "accept-language", value: language),
        ]
        return comps?.url
    }

    private struct NominatimPlace: Decodable {
        let place_id: Int?
        let osm_id: Int?
        // Nominatim returns coordinates as *strings*.
        let lat: String
        let lon: String
        let name: String?
        let display_name: String?
    }

    public static func decodeNominatim(_ data: Data) throws -> [GeocodeHit] {
        let places: [NominatimPlace]
        do {
            places = try JSONDecoder().decode([NominatimPlace].self, from: data)
        } catch {
            throw GeocodeError.decode
        }
        return places.enumerated().compactMap { idx, p in
            guard let coord = coordinate(lat: p.lat, lon: p.lon) else { return nil }
            let display = p.display_name ?? ""
            // `name` is empty for a plain address ("No. 5, Section 1,
            // …"), where the first component of display_name is the
            // most name-like thing there is.
            let title = nonEmpty(p.name)
                ?? display.split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                ?? display
            let id = p.place_id.map(String.init)
                ?? p.osm_id.map(String.init)
                ?? String(idx)
            return GeocodeHit(id: "nominatim-\(id)",
                              title: title,
                              subtitle: display,
                              coordinate: coord)
        }
    }

    // MARK: - Photon

    public static func photonURL(
        query: String,
        limit: Int = 8,
        language: String,
    ) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var comps = URLComponents(string: "https://photon.komoot.io/api/")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
            // Photon only speaks a handful of languages and 400s on
            // anything else, so a full locale identifier ("zh-Hant-TW")
            // has to be cut down to the base tag before it goes out.
            URLQueryItem(name: "lang", value: photonLanguage(language)),
        ]
        return comps?.url
    }

    /// Photon accepts de / en / fr / it; anything else is rejected, so
    /// unknown languages fall back to English rather than failing the
    /// whole request. The *results* are still local-language — the
    /// parameter only picks which translated name is preferred.
    public static func photonLanguage(_ raw: String) -> String {
        let base = raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init)?.lowercased() ?? "en"
        return ["de", "en", "fr", "it"].contains(base) ? base : "en"
    }

    private struct PhotonCollection: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable {
                /// GeoJSON order is [longitude, latitude]. Getting this
                /// backwards puts Taipei in the Indian Ocean, which is
                /// why `PhotonCoordinatesAreLonLat` exists.
                let coordinates: [Double]
            }
            struct Properties: Decodable {
                let osm_id: Int?
                let osm_type: String?
                let name: String?
                let street: String?
                let housenumber: String?
                let postcode: String?
                let city: String?
                let district: String?
                let state: String?
                let country: String?
            }
            let geometry: Geometry
            let properties: Properties
        }
        let features: [Feature]
    }

    public static func decodePhoton(_ data: Data) throws -> [GeocodeHit] {
        let collection: PhotonCollection
        do {
            collection = try JSONDecoder().decode(PhotonCollection.self, from: data)
        } catch {
            throw GeocodeError.decode
        }
        return collection.features.enumerated().compactMap { idx, f in
            let c = f.geometry.coordinates
            guard c.count >= 2 else { return nil }
            guard let coord = coordinate(lat: c[1], lon: c[0]) else { return nil }
            let p = f.properties
            let street = [p.street, p.housenumber].compactMap(nonEmpty).joined(separator: " ")
            let parts = [
                nonEmpty(street),
                nonEmpty(p.district),
                nonEmpty(p.city),
                nonEmpty(p.state),
                nonEmpty(p.country),
            ].compactMap { $0 }
            // A named place ("Taipei 101") keeps its name as the title
            // and gets the address underneath. A bare address has no
            // name, so the street line has to be promoted or the row
            // would render with an empty first line.
            let title = nonEmpty(p.name) ?? parts.first ?? "—"
            let subtitle = nonEmpty(p.name) == nil
                ? parts.dropFirst().joined(separator: ", ")
                : parts.joined(separator: ", ")
            let id = p.osm_id.map { "\(p.osm_type ?? "x")\($0)" } ?? String(idx)
            return GeocodeHit(id: "photon-\(id)",
                              title: title,
                              subtitle: subtitle,
                              coordinate: coord)
        }
    }

    // MARK: - Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    private static func coordinate(lat: String, lon: String) -> Coordinate? {
        guard let la = Double(lat), let lo = Double(lon) else { return nil }
        return coordinate(lat: la, lon: lo)
    }

    /// The one place a result is rejected for being off the planet.
    /// `Double("nan")` succeeds, so a NaN has to be caught explicitly
    /// or it propagates all the way to a map annotation that silently
    /// never draws.
    private static func coordinate(lat: Double, lon: Double) -> Coordinate? {
        guard lat.isFinite, lon.isFinite,
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Coordinate(lat: lat, lng: lon)
    }
}
