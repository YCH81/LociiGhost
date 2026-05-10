import Foundation
import MapKit
import Observation

/// Live "search-as-you-type" suggestions backed by MapKit.
///
/// `MKLocalSearchCompleter` is Apple's equivalent of Google Places
/// Autocomplete — same data set as Apple Maps, no API key, no cost,
/// no monthly quota. It pushes new completions on the main queue every
/// time `queryFragment` changes, so the SwiftUI view that owns this
/// model re-renders automatically via @Observable.
///
/// Resolving a completion to a real coordinate happens lazily: we only
/// fire `MKLocalSearch` when the user actually picks a suggestion,
/// which keeps the typing path cheap.
@MainActor
@Observable
final class MapSearchModel: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()

    /// What the user has typed. Setting this kicks the completer; clearing
    /// it cancels any in-flight request.
    var query: String = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                completions = []
                completer.queryFragment = ""
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    /// Latest suggestions for `query`. Empty until the completer responds.
    var completions: [MKLocalSearchCompletion] = []

    /// Last completer-side error message, if any. Cleared on the next
    /// successful response.
    var errorMessage: String?

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

    /// Resolve a tapped completion to a real CLLocationCoordinate2D.
    /// Throws if MapKit can't find anything for the suggestion (rare;
    /// usually network).
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> (CLLocationCoordinate2D, MKMapItem) {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw ResolveError.noResults
        }
        return (item.placemark.coordinate, item)
    }

    enum ResolveError: LocalizedError {
        case noResults
        var errorDescription: String? {
            switch self {
            case .noResults: return "Couldn't resolve that suggestion."
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
        self.completions = completer.results
        self.errorMessage = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        self.errorMessage = error.localizedDescription
        // Don't clobber the existing list -- a transient network error
        // shouldn't yank suggestions the user might still want.
    }
}
