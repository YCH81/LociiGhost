import Foundation
import LociiGhostCore

/// Google Geocoding API client — used as a fallback when Apple's
/// `MKLocalSearchCompleter` returns no matches for the user's query
/// (commonly a Chinese-language landmark / store name that Apple's
/// geocoder doesn't index well).
///
/// The user supplies their own API key from the Settings sheet. We
/// hit the public `maps.googleapis.com/maps/api/geocode/json` endpoint
/// (no SDK needed) and decode the trimmed-down response below. No
/// secrets baked into the app — the key never leaves the Mac.
///
/// **Network**: one HTTPS request per query, ~200-400 ms typical.
/// We give up after 4 seconds so a stuck request doesn't freeze the
/// search dropdown.
enum GoogleGeocodingService {

    /// One concrete hit. `formatted` is what we show in the suggestion
    /// row (Google returns localised addresses based on Accept-Language
    /// — we pass the user's preferred language so Chinese queries get
    /// Chinese results).
    struct Hit: Identifiable, Hashable {
        let id: String
        let formatted: String
        let coordinate: Coordinate
    }

    enum APIError: LocalizedError {
        case http(Int)
        case decode
        case apiStatus(String)
        case missingKey

        var errorDescription: String? {
            switch self {
            case .http(let c):     return "Google API error: HTTP \(c)"
            case .decode:          return "Google API returned an unrecognised payload."
            case .apiStatus(let s): return "Google API: \(s)"
            case .missingKey:      return "No Google API key configured."
            }
        }
    }

    private struct Payload: Decodable {
        struct Result: Decodable {
            struct Geometry: Decodable {
                struct Location: Decodable { let lat: Double; let lng: Double }
                let location: Location
            }
            let formatted_address: String?
            let geometry: Geometry
            let place_id: String?
        }
        let status: String
        let results: [Result]
        let error_message: String?
    }

    /// Resolve a free-form query to one or more coordinate hits via
    /// the Google Geocoding API. Returns [] for ZERO_RESULTS — that's
    /// not an error, just "nothing matched". Throws for HTTP / decode
    /// failures so the caller can surface the underlying reason.
    ///
    /// - Parameters:
    ///   - query: User-typed string. URL-encoded internally.
    ///   - apiKey: User-supplied Google Cloud API key with the
    ///     Geocoding API enabled.
    ///   - language: Preferred result language; tied to the app's
    ///     current locale so a Chinese UI sees Chinese addresses.
    ///   - limit: Cap on the number of hits returned to the caller
    ///     (Google itself returns at most 5-ish per request).
    static func search(
        query: String,
        apiKey: String,
        language: String = "zh-TW",
        limit: Int = 5,
    ) async throws -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard !apiKey.isEmpty else { throw APIError.missingKey }

        var comps = URLComponents(string: "https://maps.googleapis.com/maps/api/geocode/json")!
        comps.queryItems = [
            URLQueryItem(name: "address", value: trimmed),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue(language, forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw APIError.decode
        }

        switch payload.status {
        case "OK":
            return payload.results.prefix(limit).enumerated().map { idx, r in
                Hit(
                    id: r.place_id ?? "google-\(idx)",
                    formatted: r.formatted_address ?? "(no address)",
                    coordinate: Coordinate(lat: r.geometry.location.lat,
                                           lng: r.geometry.location.lng),
                )
            }
        case "ZERO_RESULTS":
            return []
        default:
            throw APIError.apiStatus(payload.error_message ?? payload.status)
        }
    }
}
