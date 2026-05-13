import Foundation

/// Tiny "is there a newer version of LociiGhost out there?" check.
///
/// Pulls a small JSON manifest from a fixed URL, compares the
/// `version` field with what we're shipping right now, and lets
/// the caller decide whether to nag the user. Failures (no
/// network, server down, malformed JSON) are silent — we never
/// want the update check to throw an error toast.
///
/// Manifest schema:
///
///     {
///       "version": "1.5.0",
///       "url": "https://github.com/.../releases/tag/v1.5.0",
///       "notes": "What changed in this release (optional, plain text)"
///     }
///
/// Host it anywhere static — a GitHub raw file in your release
/// branch is the simplest path, no server needed.
enum UpdateService {

    /// Default manifest URL. **Change this to your own release
    /// manifest** before shipping — pointing at the wrong URL is
    /// harmless (the check silently fails) but means users will
    /// never see update notifications.
    static let defaultManifestURL = URL(
        string: "https://raw.githubusercontent.com/YCH81/LociiGhost/main/latest.json"
    )!

    struct Manifest: Sendable, Decodable {
        let version: String
        let url: URL?
        let notes: String?
    }

    /// Fetch the manifest. Returns nil on any failure — caller
    /// should treat that as "no update info available right now"
    /// and try again later, never as an error to surface to the
    /// user.
    static func fetchLatest(from url: URL = defaultManifestURL) async -> Manifest? {
        var request = URLRequest(url: url)
        // Short timeout — the update check is a nice-to-have, not
        // worth blocking the app start path for more than a few
        // seconds.
        request.timeoutInterval = 5
        // Bust any cached copy — releases ship often enough that
        // we'd rather pay a fresh request than show a stale
        // version banner.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            NSLog("LociiGhost: update check failed: %@",
                  String(describing: error))
            return nil
        }
    }

    /// Numeric "is `remote` strictly newer than `current`?".
    /// Splits "1.4.0" → [1, 4, 0] and compares element-wise so
    /// "1.10.0" doesn't get treated as older than "1.9.0" the
    /// way a plain string compare would. Non-numeric segments
    /// (e.g. "1.4.0-beta") are dropped; if you ship pre-release
    /// tags you'll want to extend this.
    static func isNewer(remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        let len = max(r.count, c.count)
        for i in 0..<len {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}
