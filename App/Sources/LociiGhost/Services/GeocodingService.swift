import Foundation
import LociiGhostCore

/// One entry point for "turn this text into places", whichever
/// provider the user picked.
///
/// The URL building and response decoding live in `OSMGeocoding` in
/// Core, where a test can hold a real captured response; what's left
/// here is the part that needs a network: headers, timeouts, status
/// codes, and the polite pause the OpenStreetMap services ask for.
///
/// Apple is deliberately absent. `MKLocalSearchCompleter` is a
/// stateful, delegate-driven object that streams completions as the
/// user types and resolves them in a second step — nothing like a
/// one-shot request — so `MapSearchModel` drives it directly rather
/// than pretending it fits behind this function.
enum GeocodingService {

    /// Version string sent in the User-Agent. Read from the bundle so
    /// a blocked release can be identified by version rather than the
    /// operators having to block every LociiGhost there has ever been.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    static func search(
        provider: GeocodeProvider,
        query: String,
        language: String = Locale.current.identifier,
        limit: Int = 8,
        apiKey: String? = nil,
    ) async throws -> [GeocodeHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        switch provider {
        case .apple:
            // MapSearchModel owns this path; calling here is a
            // programming error, not a user-visible failure.
            assertionFailure("Apple search goes through MKLocalSearchCompleter")
            return []

        case .nominatim:
            guard let url = OSMGeocoding.nominatimURL(
                query: trimmed, limit: limit, language: language) else {
                throw GeocodeError.badQuery
            }
            return try await OSMGeocoding.decodeNominatim(fetch(url))

        case .photon:
            guard let url = OSMGeocoding.photonURL(
                query: trimmed, limit: limit, language: language) else {
                throw GeocodeError.badQuery
            }
            return try await OSMGeocoding.decodePhoton(fetch(url))

        case .google:
            guard let key = apiKey, !key.isEmpty else { throw GeocodeError.missingKey }
            let hits = try await GoogleGeocodingService.search(
                query: trimmed,
                apiKey: key,
                language: language,
                limit: limit,
            )
            return hits.map {
                // Google returns one formatted line and no name. The
                // first component is the closest thing to a name, and
                // repeating the whole line underneath it reads as
                // duplication, so the rest becomes the subtitle.
                let parts = $0.formatted.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                return GeocodeHit(
                    id: "google-\($0.id)",
                    title: parts.first ?? $0.formatted,
                    subtitle: parts.dropFirst().joined(separator: ", "),
                    coordinate: $0.coordinate,
                )
            }
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        // The public OSM endpoints run on donated hardware and ask
        // that clients identify themselves; a generic URLSession
        // agent is how one app gets a whole address range blocked.
        req.setValue(OSMGeocoding.userAgent(version: appVersion),
                     forHTTPHeaderField: "User-Agent")
        // Long enough for a cold Nominatim query, short enough that a
        // stuck request doesn't freeze the dropdown behind it.
        req.timeoutInterval = 6
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw GeocodeError.http(http.statusCode)
        }
        return data
    }

    /// User-facing text for a failure. `GeocodeError` is in Core,
    /// which has no localisation catalogue, so the wording lives here.
    static func message(for error: Error) -> String {
        guard let e = error as? GeocodeError else { return error.localizedDescription }
        switch e {
        case .http(429):
            return String(
                localized: "The address service is rate-limiting us — wait a moment, or switch provider in Settings.",
                comment: "Search error when the geocoding provider returns HTTP 429")
        case .http(let code):
            return String(
                format: String(localized: "Address search failed (HTTP %lld).",
                               comment: "Search error with an HTTP status code"),
                code)
        case .decode:
            return String(localized: "The address service returned something unreadable.",
                          comment: "Search error when the geocoding response won't decode")
        case .missingKey:
            return String(localized: "Add your Google API key in Settings to search with Google.",
                          comment: "Search error when Google is selected with no key")
        case .badQuery:
            return String(localized: "That search text can't be sent to the address service.",
                          comment: "Search error when the query can't be put in a URL")
        }
    }
}
