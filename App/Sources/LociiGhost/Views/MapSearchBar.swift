import SwiftUI
import MapKit
import CoreLocation
import Contacts
import AppKit
import LociiGhostCore

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
        isFocused && (!model.suggestions.isEmpty || coordCandidate != nil)
    }

    /// If the user typed something that parses as a `lat, lng` pair,
    /// surface it as a synthetic suggestion at the top of the dropdown
    /// so picking it skips geocoding entirely.
    private var coordCandidate: Coordinate? {
        Self.parseCoordinate(model.query)
    }

    var body: some View {
        // Layout: search field on top, action-button cluster on a
        // second row underneath. Earlier versions sat the four
        // buttons inline next to the field, but that made the whole
        // bar wide enough to collide with MapKit's scale indicator
        // at narrow window widths even when the bar itself was
        // centred. Stacking field over buttons cuts the bar's width
        // roughly in half so the centred layout has clearance even
        // on smaller windows.
        VStack(alignment: .center, spacing: 6) {
            field
                .frame(maxWidth: 320)
            actionButtons
            if dropdownIsVisible {
                suggestionsList
                    .frame(maxWidth: 320)
            }
            if let msg = statusMessage ?? model.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: .rect(cornerRadius: 5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 540, alignment: .leading)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        // The model holds its own copy of the provider rather than
        // reading AppState: it runs searches from a detached task and
        // has to compare the provider a response was requested under
        // with the one in force when it lands.
        .onAppear { syncProvider() }
        .onChange(of: state.geocodeProvider) { _, _ in syncProvider() }
        .onChange(of: state.googleGeocodeAPIKey) { _, _ in syncProvider() }
    }

    private func syncProvider() {
        model.apiKey = state.googleGeocodeAPIKey
        model.provider = state.geocodeProvider
    }

    /// Four buttons next to the field: Paste / Teleport / Preview /
    /// Navigate. Each shows BOTH icon and text so a new user doesn't
    /// have to hover-and-wait to learn what each glyph does.
    /// `.bordered` style gives macOS-native hover feedback for free.
    /// Wrapped in a translucent material capsule so the cluster reads
    /// as a single floating control over the map — earlier versions
    /// used `.controlSize(.small)` plain on the map and users reported
    /// the buttons visually melted into the underlying tile.
    private var actionButtons: some View {
        // Each `Text` carries `.fixedSize()` so SwiftUI can't truncate
        // long labels like "Preview" when the parent VStack thinks
        // horizontal space is tight. The cluster as a whole carries
        // `.fixedSize(horizontal:)` for the same reason at HStack level
        // — guarantees natural width regardless of the search field's
        // 320 pt cap one row up.
        HStack(spacing: 6) {
            Button {
                pasteFromClipboard()
            } label: {
                Label {
                    Text("Paste",
                         comment: "Search bar button — paste clipboard into the search field")
                        .fixedSize()
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            .help(LocalizedStringKey("Paste from clipboard"))

            Button {
                Task { await act(.teleport) }
            } label: {
                Label {
                    Text("Teleport",
                         comment: "Search bar button — move iPhone instantly")
                        .fixedSize()
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
            }
            .disabled(!hasResolvableTarget || state.isVirtualMapSelected)
            .help(LocalizedStringKey("Teleport iPhone to this location"))

            Button {
                Task { await act(.preview) }
            } label: {
                Label {
                    Text("Preview",
                         comment: "Search bar button — show on map without affecting iPhone")
                        .fixedSize()
                } icon: {
                    Image(systemName: "eye")
                }
            }
            .disabled(!hasResolvableTarget)
            .help(LocalizedStringKey("Show on map without moving the iPhone"))

            Button {
                Task { await act(.navigate) }
            } label: {
                Label {
                    Text("Navigate",
                         comment: "Search bar button — start navigation with current settings")
                        .fixedSize()
                } icon: {
                    Image(systemName: "location.north.fill")
                }
            }
            .disabled(!hasResolvableTarget || state.isVirtualMapSelected)
            .help(LocalizedStringKey("Navigate to this location with current settings"))
        }
        .controlSize(.regular)
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 0.5)
        )
    }

    /// True when there's something we can resolve to coords:
    /// either a typed `lat,lng` OR at least one autocomplete result
    /// (we'll take the first one for the action).
    private var hasResolvableTarget: Bool {
        coordCandidate != nil || !model.suggestions.isEmpty
    }

    private enum SearchAction { case teleport, preview, navigate }

    /// Resolve whatever the user has in the field to a single
    /// Coordinate, then dispatch the chosen action. Centralised so
    /// the three buttons share resolution rather than each duplicating
    /// the typed-coord vs. completion fallback logic.
    @MainActor
    private func act(_ action: SearchAction) async {
        let coord: Coordinate
        if let c = coordCandidate {
            coord = c
        } else if let first = model.suggestions.first {
            resolvingTitle = first.title
            defer { resolvingTitle = nil }
            do {
                let resolved = try await model.resolve(first)
                coord = resolved.coordinate
                model.query = resolved.name
                model.suggestions = []
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
                return
            }
        } else if let googleHit = await tryGoogleFallback() {
            // The chosen provider returned nothing usable (common for
            // Chinese store / landmark names against Apple's index).
            // Fall back to Google if the user has a key in Settings.
            // We replace the search field with the resolved address so
            // the user sees what Google matched.
            coord = googleHit.coordinate
            model.query = googleHit.title
            model.suggestions = []
        } else {
            statusIsError = true
            statusMessage = String(
                localized: "Type an address or lat,lng first.",
                comment: "Search bar — error when an action button is hit with empty field",
            )
            return
        }
        statusIsError = false
        isFocused = false

        // Friendly label used for the recent-places log. If the user
        // resolved a completion the model.query was rewritten to the
        // place's display name; for raw coord-typed input we fall
        // back to the formatted lat/lng so the popover row stays
        // readable.
        let trimmedQuery = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentLabel: String
        if coordCandidate != nil {
            recentLabel = String(format: "%.5f, %.5f", coord.lat, coord.lng)
        } else {
            recentLabel = trimmedQuery
        }
        let recentKind: RecentPlace.Kind = (coordCandidate != nil) ? .coord : .search

        switch action {
        case .preview:
            // Just fly there. No teleport, no navigation. The user
            // is browsing — still log it, so re-opening the popover
            // can re-fly to a previously-previewed place.
            // v1.11.2: also drop a search-preview marker at the
            // coord so the user can see where they previewed —
            // before this, the map silently panned with no visible
            // indication of the previewed point.
            state.pendingMapFly = MapFlyRequest(coordinate: coord, spanMeters: 2_500)
            state.searchPreviewCoord = coord
            state.recordRecentPlace(label: recentLabel, lat: coord.lat, lng: coord.lng, kind: recentKind)
            statusMessage = String(format: "Previewing %.5f, %.5f", coord.lat, coord.lng)

        case .teleport:
            guard let udid = state.selectedUDID,
                  state.devices.first(where: { $0.udid == udid })?.connected == true
            else {
                statusIsError = true
                statusMessage = String(localized: "Connect a device first.")
                return
            }
            state.pendingMapFly = MapFlyRequest(coordinate: coord, spanMeters: 2_000)
            // v1.11.2: teleporting commits the action — clear any
            // lingering search-preview marker since the simulated
            // pin now occupies that spot.
            state.searchPreviewCoord = nil
            await state.teleport(udid: udid, lat: coord.lat, lng: coord.lng)
            // Overwrite the coord-only label inserted by `teleport(...)`
            // with the friendlier "place name" string from the search
            // field. recordRecentPlace de-dupes on label+coord, so the
            // duplicate same-coord entry is collapsed into the one
            // with the better label.
            state.recordRecentPlace(label: recentLabel, lat: coord.lat, lng: coord.lng, kind: recentKind)
            statusMessage = String(format: "Teleported to %.5f, %.5f", coord.lat, coord.lng)

        case .navigate:
            guard let udid = state.selectedUDID,
                  state.devices.first(where: { $0.udid == udid })?.connected == true
            else {
                statusIsError = true
                statusMessage = String(localized: "Connect a device first.")
                return
            }
            // Use current profile + user-set custom speed (or the
            // profile's default). Mirrors what the bottom-bar
            // controls do when the user hits Navigate manually.
            let speed = state.customSpeedMps ?? state.travelProfile.defaultSpeedMps
            state.pendingMapFly = MapFlyRequest(coordinate: coord, spanMeters: 4_000)
            // v1.11.2: navigating commits the action — clear any
            // lingering search-preview marker since the destination
            // pin now claims that spot.
            state.searchPreviewCoord = nil
            await state.navigate(
                udid: udid,
                through: [coord],
                profile: state.travelProfile,
                speed: speed,
            )
            state.recordRecentPlace(label: recentLabel, lat: coord.lat, lng: coord.lng, kind: .navigate)
            statusMessage = String(format: "Navigating to %.5f, %.5f", coord.lat, coord.lng)
        }
    }

    private func pasteFromClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string),
              !s.isEmpty else { return }
        model.query = s
        // If the pasted text is a valid coord pair, the suggestions
        // dropdown's CoordinateRow will surface it automatically; the
        // user can hit one of the action buttons next.
    }

    // MARK: - Subviews

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search address or place", text: $model.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                // v1.11.2: Enter triggers Teleport (the most common
                // "I want to go here now" intent), not Paste-as-stop.
                // Clicking a row in the suggestions list below still
                // appends to pendingStops (multi-stop staging path),
                // so both intents remain reachable — Enter is the
                // one-shot shortcut.
                .onSubmit { Task { await act(.teleport) } }
            if resolvingTitle != nil || model.isSearching {
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
                .strokeBorder(isFocused ? Color.lociSage.opacity(0.6) : Color.clear,
                              lineWidth: 1.5)
        )
    }

    /// One autocomplete suggestion with a content-derived identity.
    ///
    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let coord = coordCandidate {
                CoordinateRow(coordinate: coord)
                    .contentShape(.rect)
                    .onTapGesture { pickCoordinate(coord) }
                if !model.suggestions.isEmpty {
                    Divider().padding(.leading, 12)
                }
            }
            ForEach(model.suggestions) { item in
                SuggestionRow(title: item.title, subtitle: item.subtitle)
                    .contentShape(.rect)
                    .onTapGesture {
                        Task { await pick(item) }
                    }
                Divider().padding(.leading, 12)
            }
            // Required by ODbL for the OpenStreetMap-derived
            // providers, and useful for the others: when a search
            // finds nothing, the first question is which service was
            // asked.
            if let credit = model.provider.attribution, !model.suggestions.isEmpty {
                Text(credit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
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
        guard let first = model.suggestions.first else {
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
        model.suggestions = []
        isFocused = false
        statusIsError = false
        statusMessage = String(format: "Coordinates set: %.6f, %.6f", coord.lat, coord.lng)
    }

    @MainActor
    private func pick(_ suggestion: SearchSuggestion) async {
        resolvingTitle = suggestion.title
        defer { resolvingTitle = nil }
        do {
            let resolved = try await model.resolve(suggestion)
            state.pendingStops.append(resolved.coordinate)
            state.pendingMapFly = MapFlyRequest(coordinate: resolved.coordinate,
                                                spanMeters: 2_500)

            // Replace the live query with the friendly name so the user
            // sees what was selected; suppress further suggestions by
            // dropping focus.
            model.query = resolved.name
            model.suggestions = []
            isFocused = false
            statusIsError = false
            statusMessage = resolved.detail
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    /// Try Google when the chosen provider produced nothing.
    ///
    /// Only a fallback, never a silent replacement: if the user picked
    /// Google it is already the provider, and if they picked one of the
    /// others we still fall back rather than leave them stuck on a
    /// query Apple's index doesn't cover — but only when they have
    /// supplied a key, since every one of these requests is billed to
    /// them. Errors surface through `statusMessage` so a bad key reads
    /// as "REQUEST_DENIED" rather than as no results.
    @MainActor
    private func tryGoogleFallback() async -> GeocodeHit? {
        guard state.geocodeProvider != .google,
              let key = state.googleGeocodeAPIKey, !key.isEmpty else { return nil }
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        resolvingTitle = query
        defer { resolvingTitle = nil }

        do {
            return try await GeocodingService.search(
                provider: .google,
                query: query,
                limit: 1,
                apiKey: key,
            ).first
        } catch {
            statusIsError = true
            statusMessage = "Google fallback: \(GeocodingService.message(for: error))"
            return nil
        }
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
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
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
        subtitle.isEmpty ? "mappin.and.ellipse" : "magnifyingglass"
    }
}
