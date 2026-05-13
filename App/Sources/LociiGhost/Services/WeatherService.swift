import Foundation
import LociiGhostCore

/// Tiny Open-Meteo client. Picked Open-Meteo because it has no API
/// key, no per-day quota for personal use, and a single endpoint that
/// returns both current temperature and a WMO weather code we can map
/// to the five-icon set the user asked for (sun / rain / snow / hail /
/// cloud).
///
/// The status-bar caller polls infrequently — typically only after a
/// teleport / route-start moves the simulated location — so we don't
/// need session pooling or anything fancy. URLSession.shared is fine.
enum WeatherService {

    /// What we surface to the UI. Temperature in Celsius (Open-Meteo's
    /// default), condition mapped from WMO code into the five buckets.
    struct Snapshot: Sendable, Equatable {
        let temperatureC: Double
        let condition: Condition
    }

    /// Five buckets the user asked for: sun / cloud / rain / snow /
    /// hail. We collapse Open-Meteo's 27-code WMO scheme into these.
    enum Condition: String, Sendable {
        case sunny, cloudy, rain, snow, hail

        /// SF Symbol the status bar paints. Filled variants because
        /// the bar is dense and outline glyphs get lost.
        var symbol: String {
            switch self {
            case .sunny:  return "sun.max.fill"
            case .cloudy: return "cloud.fill"
            case .rain:   return "cloud.rain.fill"
            case .snow:   return "snowflake"
            case .hail:   return "cloud.hail.fill"
            }
        }
    }

    /// Open-Meteo's current-conditions endpoint. We pin
    /// `temperature_2m` (the standard 2 m above ground reading) and
    /// `weather_code` (the WMO code). No timezone param — the
    /// temperature is instantaneous so it's the same whether you ask
    /// in UTC or local.
    static func fetch(lat: Double, lng: Double) async throws -> Snapshot {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",  value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lng)),
            URLQueryItem(name: "current",   value: "temperature_2m,weather_code"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WeatherError.httpStatus(http.statusCode)
        }
        struct Reply: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
            }
            let current: Current
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Snapshot(
            temperatureC: reply.current.temperature_2m,
            condition: condition(forWMO: reply.current.weather_code),
        )
    }

    /// WMO weather-code → Condition. Codes per
    /// https://open-meteo.com/en/docs (table near the bottom).
    private static func condition(forWMO code: Int) -> Condition {
        switch code {
        case 0, 1:                                  return .sunny
        case 2, 3, 45, 48:                          return .cloudy
        case 51...67, 80...82:                      return .rain
        case 71...77, 85, 86:                       return .snow
        case 95...99:                               return .hail
        default:                                    return .cloudy
        }
    }
}

enum WeatherError: LocalizedError {
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "weather: HTTP \(code)"
        }
    }
}
