import Foundation
import LociiGhostCore

/// Tiny GPX 1.1 reader / writer. Uses Foundation's `XMLParser` for
/// decode (zero new deps) and string templating for encode.
///
/// What we read:
///   - `<wpt lat lon>` waypoints (treated as ordered stops)
///   - `<trk><trkseg><trkpt lat lon>` track points (also treated as
///     stops, in segment order)
///
/// What we write:
///   - `<trk><trkseg><trkpt lat lon>` for each Coordinate. We pick
///     trk-style over wpt-style because consumers (Garmin, Strava,
///     even Apple's own preview) reliably render the connecting line
///     for trkpt sequences but treat wpt as discrete pin clouds.
enum GPXService {

    // ── Decode ────────────────────────────────────────────────────

    /// Parse a `.gpx` file into an ordered list of Coordinates.
    /// Throws `GPXError.unparseable` on a malformed document.
    static func loadCoordinates(from url: URL) throws -> [Coordinate] {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let delegate = _GPXParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXError.unparseable(parser.parserError?.localizedDescription
                                       ?? "unknown parse failure")
        }
        let coords = delegate.coords
        guard !coords.isEmpty else {
            throw GPXError.empty
        }
        return coords
    }

    // ── Encode ────────────────────────────────────────────────────

    /// Serialise a list of Coordinates to a `.gpx` document. We emit
    /// a single `<trk>` with one `<trkseg>` so any reader draws the
    /// correct connecting polyline.
    static func gpxString(coordinates: [Coordinate],
                          name: String = "LociiGhost route") -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="LociiGhost"
             xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(_xmlEscape(name))</name>
            <time>\(now)</time>
          </metadata>
          <trk>
            <name>\(_xmlEscape(name))</name>
            <trkseg>

        """
        for c in coordinates {
            s += String(
                format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n",
                c.lat, c.lng,
            )
        }
        s += """
            </trkseg>
          </trk>
        </gpx>
        """
        return s
    }

    static func write(coordinates: [Coordinate], to url: URL,
                      name: String = "LociiGhost route") throws {
        let txt = gpxString(coordinates: coordinates, name: name)
        // v1.15.2 audit (L18): `data(using:)?.write(...)` evaluates to
        // nothing when the encode returns nil, and the function then
        // returned successfully having written no file — the UI
        // reported a successful export of something that wasn't there.
        guard let data = txt.data(using: .utf8) else {
            throw GPXError.unparseable("could not encode the route as UTF-8")
        }
        try data.write(to: url, options: .atomic)
    }
}

enum GPXError: LocalizedError {
    case unparseable(String)
    case empty
    var errorDescription: String? {
        switch self {
        case .unparseable(let why):
            return String(localized: "GPX file is malformed: \(why)",
                          comment: "Error when GPX import fails to parse")
        case .empty:
            return String(localized: "GPX file has no waypoints or track points.",
                          comment: "Error when imported GPX has no usable coords")
        }
    }
}

// ── XMLParser delegate ────────────────────────────────────────────

private final class _GPXParserDelegate: NSObject, XMLParserDelegate {
    /// Combined output. We collect waypoints first (because they
    /// appear before tracks in well-formed GPX), then track points.
    /// Most GPX files are EITHER waypoints OR tracks, not both, so
    /// the ordering ambiguity rarely bites.
    var coords: [Coordinate] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        // GPX files commonly use lowercase element names; some
        // exports throw in mixed case. Normalise.
        let name = elementName.lowercased()
        guard name == "wpt" || name == "trkpt" || name == "rtept" else { return }
        guard let latStr = attributeDict["lat"] ?? attributeDict["LAT"],
              let lonStr = attributeDict["lon"] ?? attributeDict["LON"],
              let lat = Double(latStr),
              let lng = Double(lonStr)
        else { return }
        coords.append(Coordinate(lat: lat, lng: lng))
    }
}

// ── Helpers ──────────────────────────────────────────────────────

private func _xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}
