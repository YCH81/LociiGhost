import SwiftUI
import MapKit
import CoreLocation
import Contacts

/// Floating search field on top of the map.
///
/// Powered by `MapSearchModel` (an `MKLocalSearchCompleter` wrapper).
/// As the user types, suggestions stream in from Apple Maps' database
/// and render as a floating list directly below the text field. The
/// user picks one, we resolve it to a real coordinate, drop a pending
/// target there, and ask the map to fly to the spot. We don't auto-
/// teleport — the iPhone only moves once the user hits the actual
/// Teleport button.
struct MapSearchBar: View {
    @Environment(AppState.self) private var state
    @State private var model = MapSearchModel()
    @State private var resolvingTitle: String?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @FocusState private var isFocused: Bool

    private var dropdownIsVisible: Bool {
        isFocused && (!model.completions.isEmpty || coordCandidate != nil)
    }

    /// If the user typed something that parses as a `lat, lng` pair,
    /// surface it as a synthetic suggestion at the top of the dropdown
    /// so picking it skips geocoding entirely.
    private var coordCandidate: Coordinate? {
        Self.parseCoordinate(model.query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
            if dropdownIsVisible {
                suggestionsList
            }
            if let msg = statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: .rect(cornerRadius: 5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .frame(maxWidth: 360)
    }

    // MARK: - Subviews

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search address or place", text: $model.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { Task { await pickFirst() } }
            if resolvingTitle != nil {
                ProgressView().controlSize(.small)
            } else if !model.query.isEmpty {
                Button {
                    model.clear()
                    statusMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.clear,
                              lineWidth: 1.5)
        )
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let coord = coordCandidate {
                CoordinateRow(coordinate: coord)
                    .contentShape(.rect)
                    .onTapGesture { pickCoordinate(coord) }
                if !model.completions.isEmpty {
                    Divider().padding(.leading, 12)
                }
            }
            ForEach(Array(model.completions.prefix(8).enumerated()), id: \.offset) { _, completion in
                SuggestionRow(completion: completion)
                    .contentShape(.rect)
                    .onTapGesture {
                        Task { await pick(completion) }
                    }
                Divider().padding(.leading, 12)
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
    }

    // MARK: - Actions

    @MainActor
    private func pickFirst() async {
        // Direct lat,lng input wins over autocomplete: if the user typed
        // something like "37.78, -122.41" they almost certainly want THAT
        // exact spot, not a fuzzy match.
        if let coord = coordCandidate {
            pickCoordinate(coord)
            return
        }
        guard let first = model.completions.first else {
            statusIsError = true
            statusMessage = "No suggestions yet — keep typing."
            return
        }
        await pick(first)
    }

    @MainActor
    private func pickCoordinate(_ coord: Coordinate) {
        state.pendingStops.append(coord)
        state.pendingMapFly = MapFlyRequest(coordinate: coord, spanMeters: 2_000)
        model.completions = []
        isFocused = false
        statusIsError = false
        statusMessage = String(format: "Coordinates set: %.6f, %.6f", coord.lat, coord.lng)
    }

    @MainActor
    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolvingTitle = completion.title
        defer { resolvingTitle = nil }
        do {
            let (coord, item) = try await model.resolve(completion)
            let cc = Coordinate(lat: coord.latitude, lng: coord.longitude)
            state.pendingStops.append(cc)
            state.pendingMapFly = MapFlyRequest(coordinate: cc, spanMeters: 2_500)

            // Replace the live query with the friendly name so the user
            // sees what was selected; suppress further suggestions by
            // dropping focus.
            model.query = item.name ?? completion.title
            model.completions = []
            isFocused = false
            statusIsError = false
            statusMessage = formattedAddress(item: item, fallback: completion)
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func formattedAddress(item: MKMapItem, fallback: MKLocalSearchCompletion) -> String {
        if let postal = item.placemark.postalAddress {
            let parts = [postal.street, postal.city, postal.country].filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return fallback.subtitle.isEmpty ? fallback.title : "\(fallback.title) — \(fallback.subtitle)"
    }

    /// Parse strings like `"37.779, -122.418"`, `"25.04 121.56"`, or
    /// `"  -33.86 ,  151.21 "` into a Coordinate. Returns nil if the text
    /// doesn't look like a coord pair or any value is out of range.
    static func parseCoordinate(_ input: String) -> Coordinate? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Accept comma-, semicolon-, or whitespace-separated.
        let pieces = trimmed
            .split(whereSeparator: { ",;\t ".contains($0) })
            .map { String($0) }
            .filter { !$0.isEmpty }

        guard pieces.count == 2,
              let lat = Double(pieces[0]),
              let lng = Double(pieces[1]),
              (-90.0...90.0).contains(lat),
              (-180.0...180.0).contains(lng)
        else {
            return nil
        }
        return Coordinate(lat: lat, lng: lng)
    }
}

// MARK: - Suggestion row

/// Synthetic dropdown row shown when the typed string parses as a coord
/// pair. Picking it skips MapKit geocoding entirely.
private struct CoordinateRow: View {
    let coordinate: Coordinate

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Use exact coordinates")
                    .font(.body)
                Text(String(format: "%.6f, %.6f", coordinate.lat, coordinate.lng))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SuggestionRow: View {
    let completion: MKLocalSearchCompletion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.body)
                    .lineLimit(1)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Distinguish landmarks ("Eiffel Tower") from raw addresses
    /// ("123 Main St") with a different SF Symbol.
    private var glyph: String {
        completion.subtitle.isEmpty ? "mappin.and.ellipse" : "magnifyingglass"
    }
}
