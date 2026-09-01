import Foundation

/// One bookmark, in the shape GPX can carry it.
///
/// Deliberately not `Bookmark` (which is a SwiftData `@Model` living
/// in the app target): the file format is a pure value problem, so it
/// lives in Core where a round-trip can be tested without a
/// `ModelContainer`. The app target maps between the two in one place.
public struct BookmarkWaypoint: Sendable, Equatable {
    public var name: String
    public var lat: Double
    public var lng: Double
    /// Free-form category name. Empty means uncategorised.
    public var category: String
    /// `Bookmark.iconSymbol` verbatim — an SF Symbol name, or a
    /// `flower.<id>` value (see `FlowerPin.symbolPrefix`).
    public var symbol: String?
    /// The category's colour **only when the user chose one**.
    ///
    /// Derived colours are deliberately not written: `CategoryPalette`
    /// computes them from the name with a hash we own, so they are
    /// already identical on every machine. Writing them would turn
    /// every derived colour into an explicit override on import, which
    /// silently freezes colours the user never picked.
    public var colorHex: String?
    public var imageURL: String?

    public init(
        name: String,
        lat: Double,
        lng: Double,
        category: String = "",
        symbol: String? = nil,
        colorHex: String? = nil,
        imageURL: String? = nil,
    ) {
        self.name = name
        self.lat = lat
        self.lng = lng
        self.category = category
        self.symbol = symbol
        self.colorHex = colorHex
        self.imageURL = imageURL
    }
}

public enum BookmarkGPXError: Error, Equatable {
    case unparseable(String)
    case empty
}

/// GPX 1.1 `<wpt>` reader / writer for bookmarks.
///
/// Separate from `GPXService` (routes) on purpose. A route is an
/// ordered path and is written as `<trk>` so every reader draws the
/// connecting line; a bookmark set is a pin cloud with names, and
/// `<wpt>` is the tag every other app understands as exactly that.
/// Mixing them into one encoder would mean one function whose output
/// shape depends on a flag, and two callers each hoping it picked
/// theirs.
///
/// Everything except the colour maps onto standard GPX:
///
///   - `<name>` — the bookmark's name
///   - `<type>` — the category (GPX 1.1 defines `type` as the
///     waypoint's classification, which is what a category is)
///   - `<sym>` — the icon. Other apps show their own default when
///     they don't recognise the value, which is the correct failure.
///   - `<link href>` — the photo URL
///
/// Only the colour has no standard home, so it goes in `<extensions>`
/// under our own namespace. Readers are required to ignore extensions
/// they don't know, so the file stays valid GPX everywhere else.
public enum BookmarkGPX {

    /// Namespace for our one extension element. A URI, per XML rules;
    /// it is an identifier, not an address that has to resolve.
    public static let namespaceURI = "https://lociighost.app/gpx/1"
    /// Prefix we emit it under.
    public static let namespacePrefix = "lociighost"

    // MARK: - Encode

    public static func encode(
        _ waypoints: [BookmarkWaypoint],
        name: String = "LociiGhost bookmarks",
        date: Date = .now,
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="LociiGhost"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:\(namespacePrefix)="\(namespaceURI)">
          <metadata>
            <name>\(escape(name))</name>
            <time>\(formatter.string(from: date))</time>
          </metadata>

        """
        for w in waypoints {
            // `%.6f` is ~11 cm at the equator. Bookmarks are places,
            // not survey marks, and six places keeps the file readable.
            s += String(format: "  <wpt lat=\"%.6f\" lon=\"%.6f\">\n", w.lat, w.lng)
            s += "    <name>\(escape(w.name))</name>\n"
            let category = w.category.trimmingCharacters(in: .whitespacesAndNewlines)
            if !category.isEmpty {
                s += "    <type>\(escape(category))</type>\n"
            }
            if let sym = nonEmpty(w.symbol) {
                s += "    <sym>\(escape(sym))</sym>\n"
            }
            if let img = nonEmpty(w.imageURL) {
                s += "    <link href=\"\(escape(img))\"/>\n"
            }
            if let hex = w.colorHex.flatMap(CategoryPalette.normalisedHex) {
                s += """
                        <extensions>
                          <\(namespacePrefix):color>\(hex)</\(namespacePrefix):color>
                        </extensions>

                """
            }
            s += "  </wpt>\n"
        }
        s += "</gpx>"
        return s
    }

    // MARK: - Decode

    /// Parse a `.gpx` document into bookmark waypoints.
    ///
    /// Accepts any GPX file, not just ours: a plain `<wpt>` from some
    /// other app arrives with an empty category and no symbol, which
    /// is exactly what an unconfigured bookmark looks like. `<trkpt>`
    /// and `<rtept>` are ignored here — a track is a route, and
    /// importing a 4 000-point track as 4 000 bookmarks is never what
    /// anyone meant.
    public static func decode(_ data: Data) throws -> [BookmarkWaypoint] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = WaypointParser()
        parser.delegate = delegate
        guard parser.parse() else {
            throw BookmarkGPXError.unparseable(
                parser.parserError?.localizedDescription ?? "unknown parse failure")
        }
        guard !delegate.waypoints.isEmpty else { throw BookmarkGPXError.empty }
        return delegate.waypoints
    }

    // MARK: - Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    /// `&` first, or every entity we then write gets re-escaped.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - XMLParser delegate

/// Collects `<wpt>` elements and their child text.
///
/// Depth is tracked relative to the open `<wpt>` so a `<name>` in
/// `<metadata>` — or one nested inside `<extensions>` by some other
/// app — can't overwrite a waypoint's own name.
private final class WaypointParser: NSObject, XMLParserDelegate {
    var waypoints: [BookmarkWaypoint] = []

    private var current: BookmarkWaypoint?
    private var depth = 0
    private var buffer = ""
    private var capturing = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:],
    ) {
        let local = elementName.lowercased()

        if current == nil {
            guard local == "wpt",
                  let lat = coordinate(attributeDict["lat"], limit: 90),
                  let lng = coordinate(attributeDict["lon"], limit: 180)
            else { return }
            current = BookmarkWaypoint(name: "", lat: lat, lng: lng)
            depth = 0
            return
        }

        depth += 1
        buffer = ""
        capturing = false

        if depth == 1 {
            switch local {
            case "name", "type", "sym":
                capturing = true
            case "link":
                // GPX puts the URL in the attribute; the child
                // <text> is a label, not the target. An empty href is
                // left as nil rather than stored as "".
                if let href = attributeDict["href"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !href.isEmpty {
                    current?.imageURL = href
                }
            default:
                break
            }
        } else if local == "color" {
            // Inside <extensions>. We accept it at any depth and from
            // any namespace: an exporter that re-writes the file may
            // move it or drop the prefix, and a colour is cosmetic —
            // being strict here would lose it for no gain.
            capturing = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
    ) {
        guard var wpt = current else { return }
        let local = elementName.lowercased()

        if local == "wpt", depth == 0 {
            waypoints.append(wpt)
            current = nil
            capturing = false
            return
        }

        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if capturing, !text.isEmpty {
            switch local {
            case "name":  wpt.name = text
            case "type":  wpt.category = text
            case "sym":   wpt.symbol = text
            case "color": wpt.colorHex = CategoryPalette.normalisedHex(text)
            default:      break
            }
            current = wpt
        }

        buffer = ""
        capturing = false
        depth = max(0, depth - 1)
    }

    private func coordinate(_ raw: String?, limit: Double) -> Double? {
        guard let raw, let v = Double(raw), v.isFinite, abs(v) <= limit else { return nil }
        return v
    }
}
