import Foundation
import MapKit
import Observation
import LociiGhostCore

/// One row in the search dropdown, whichever provider produced it.
///
/// Apple's suggestions are a two-step affair — a completion is a
/// *promise* of a place that has to be resolved with a second network
/// call — while every other provider hands back the coordinate in the
/// first response. Modelling both as one enum keeps that difference in
/// exactly one place (`MapSearchModel.resolve`) instead of spreading a
/// provider check through the view.
enum SearchSuggestion: Identifiable {
    case completion(MKLocalSearchCompletion, id: String)
    case hit(GeocodeHit)

    var id: String {
        switch self {
        case .completion(_, let id): return id
        case .hit(let h):            return h.id
        }
    }

    var title: String {
        switch self {
        case .completion(let c, _): return c.title
        case .hit(let h):           return h.title
        }
    }

    var subtitle: String {
        switch self {
        case .completion(let c, _): return c.subtitle
        case .hit(let h):           return h.subtitle
        }
    }
}

/// Live "search-as-you-type" suggestions from whichever provider the
/// user picked.
///
/// Apple's `MKLocalSearchCompleter` is the default: same data as Apple
/// Maps, no API key, no quota, and the only one of the four that is
/// genuinely designed to be asked on every keystroke. The other three
/// are one HTTPS request per search, held back until the user stops
/// typing — for Nominatim that pause is a condition of using the
/// service at all, not a nicety.
@MainActor
@Observable
final class MapSearchModel: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()

    /// Which service to ask. Set by the view from `AppState`.
    /// Changing it re-runs the current query so the dropdown doesn't
    /// keep showing the previous provider's answers.
    var provider: GeocodeProvider = .apple {
        didSet {
            guard provider != oldValue else { return }
            suggestions = []
            errorMessage = nil
            scheduleSearch()
        }
    }

    /// Google's key, when the user has one. Nil for every other
    /// provider — and for Google without a key, which surfaces as a
    /// "add your key" message rather than an empty dropdown.
    var apiKey: String?

    /// What the user has typed. Setting this schedules a search;
    /// clearing it cancels anything in flight.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Latest suggestions for `query`. Empty until a provider answers.
    var suggestions: [SearchSuggestion] = []

    /// Last provider-side error, if any. Cleared on the next
    /// successful response.
    var errorMessage: String?

    /// True while a non-Apple provider has a request in flight, so the
    /// field can show a spinner. Apple's completer streams results and
    /// has no meaningful "in flight" state.
    var isSearching = false

    override init() {
        super.init()
        completer.delegate = self
        // Both are reasonable for a "where do I want to teleport" UX:
        // street addresses for precise targets, points of interest for
        // landmark-style queries like "Eiffel Tower".
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func clear() {
        query = ""
    }

    // MARK: - Dispatch

    /// Debounce, then ask the current provider.
    ///
    /// v1.15.2 audit (P8) put a 250 ms debounce on the Apple path
    /// because a burst of keystrokes rebuilt the dropdown mid-word.
    /// The interval is now the provider's, because Nominatim's usage
    /// policy caps one client at roughly one request a second and
    /// treats per-keystroke autocomplete as abuse — the same mechanism
    /// serving two very different reasons.
    private func scheduleSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask?.cancel()

        guard !trimmed.isEmpty else {
            suggestions = []
            errorMessage = nil
            isSearching = false
            completer.queryFragment = ""
            return
        }

        let provider = self.provider
        let key = self.apiKey
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: provider.minimumRequestInterval)
            guard !Task.isCancelled, let self else { return }

            guard provider != .apple else {
                self.completer.queryFragment = trimmed
                return
            }

            self.isSearching = true
            defer { self.isSearching = false }
            do {
                let hits = try await GeocodingService.search(
                    provider: provider,
                    query: trimmed,
                    apiKey: key,
                )
                // The user may have typed on, or switched provider,
                // while this was in the air. Dropping a stale response
                // is the whole reason the task captures its own
                // provider and compares afterwards.
                guard !Task.isCancelled,
                      provider == self.provider,
                      trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return }
                self.suggestions = hits.map { .hit($0) }
                self.errorMessage = nil
            } catch {
                guard !Task.isCancelled, provider == self.provider else { return }
                self.errorMessage = GeocodingService.message(for: error)
                // Leave the previous list alone: a transient failure
                // shouldn't yank suggestions the user might still want.
            }
        }
    }

    // MARK: - Resolving

    /// Turn a picked row into a real coordinate.
    ///
    /// Apple's completions need a second `MKLocalSearch` round trip;
    /// every other provider already answered with coordinates, so this
    /// returns immediately for those.
    func resolve(_ suggestion: SearchSuggestion) async throws
        -> (coordinate: Coordinate, name: String, detail: String) {
        switch suggestion {
        case .hit(let h):
            return (h.coordinate, h.title, h.subtitle.isEmpty ? h.title : h.subtitle)

        case .completion(let completion, _):
            let request = MKLocalSearch.Request(completion: completion)
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                throw ResolveError.noResults
            }
            let coord = item.placemark.coordinate
            return (
                Coordinate(lat: coord.latitude, lng: coord.longitude),
                item.name ?? completion.title,
                Self.formattedAddress(item: item, fallback: completion)
            )
        }
    }

    private static func formattedAddress(
        item: MKMapItem,
        fallback: MKLocalSearchCompletion,
    ) -> String {
        if let postal = item.placemark.postalAddress {
            let parts = [postal.street, postal.city, postal.country].filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return fallback.subtitle.isEmpty
            ? fallback.title
            : "\(fallback.title) — \(fallback.subtitle)"
    }

    enum ResolveError: LocalizedError {
        case noResults
        var errorDescription: String? {
            switch self {
            case .noResults:
                return String(localized: "Couldn't resolve that suggestion.",
                              comment: "Error when a picked suggestion has no coordinate")
            }
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate
    //
    // MapKit guarantees these fire on the main queue. Marking the
    // conformance @preconcurrency tells Swift 6 to accept the @MainActor
    // class methods as a valid implementation of the @objc protocol, so we
    // don't have to wrap the delegate body in an unsafe Sendable shim.

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // A late completer callback after the user switched to another
        // provider would otherwise repopulate the dropdown with Apple
        // results under a Nominatim heading.
        guard provider == .apple else { return }
        suggestions = Self.identified(completer.results)
        errorMessage = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard provider == .apple else { return }
        errorMessage = error.localizedDescription
        // Don't clobber the existing list -- a transient network error
        // shouldn't yank suggestions the user might still want.
    }

    /// v1.15.2 audit (P8): the list used `id: \.offset`, so when a new
    /// set of completions arrived SwiftUI reused row 0's view for a
    /// suggestion with entirely different text. Identity follows the
    /// content, with a counter only as a tiebreaker for genuinely
    /// duplicated entries.
    private static func identified(_ results: [MKLocalSearchCompletion]) -> [SearchSuggestion] {
        var seen: [String: Int] = [:]
        return results.prefix(8).map { c in
            let base = "\(c.title)|\(c.subtitle)"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return .completion(c, id: n == 0 ? base : "\(base)#\(n)")
        }
    }
}
