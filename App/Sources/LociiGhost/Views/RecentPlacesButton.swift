import SwiftUI
import SwiftData
import LociiGhostCore

/// Capsule button + popover for the v1.9 "Recent Places" feature.
///
/// Sits in the map's top-right cluster next to QuickRecenterButton +
/// MapLayerPicker. The capsule's badge shows the current row count;
/// tapping opens a popover with up to 30 rows, newest first. Each row
/// has a kind glyph, label, time-ago caption, and a tap-target that
/// re-flies (teleport rows) or re-plans navigation (navigate rows).
struct RecentPlacesButton: View {
    @Environment(AppState.self) private var state
    @Query(sort: \RecentPlace.createdAt, order: .reverse) private var places: [RecentPlace]
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Recent",
                     comment: "Map overlay capsule — opens the Recent Places popover")
                if !places.isEmpty {
                    Text("\(min(places.count, 99))")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.lociSage, in: .capsule)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
            .overlay(
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey("Recent teleports / navigates / searches"))
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            RecentPlacesPopover(places: places, close: { isOpen = false })
                .environment(state)
                .frame(width: 320)
        }
    }
}

private struct RecentPlacesPopover: View {
    @Environment(AppState.self) private var state
    let places: [RecentPlace]
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.tint)
                Text("Recent Places",
                     comment: "Recent Places popover title")
                    .font(.headline)
                Spacer()
                if !places.isEmpty {
                    Button(role: .destructive) {
                        state.clearRecentPlaces()
                    } label: {
                        Text("Clear",
                             comment: "Recent Places popover — clear-history button")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(LocalizedStringKey("Clear all recent places"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if places.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No history yet",
                         comment: "Empty-state title in the Recent Places popover")
                        .font(.subheadline.weight(.semibold))
                    Text("Teleports, searches, and navigations show up here so you can jump back with one tap.",
                         comment: "Empty-state hint in the Recent Places popover")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(places.prefix(30)) { entry in
                            RecentPlaceRow(entry: entry, close: close)
                                .environment(state)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }
}

private struct RecentPlaceRow: View {
    @Environment(AppState.self) private var state
    let entry: RecentPlace
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .background(Color.lociSage.opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.lociSage.opacity(0.85), in: .capsule)
                    Text(timeAgo(entry.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.4f, %.4f", entry.lat, entry.lng))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            // X button — only shown on hover, so the row stays clean
            // by default but the user can prune individual entries
            // without having to "Clear all".
            if isHovering {
                Button {
                    state.deleteRecentPlace(entry)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey("Remove from history"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .background(isHovering ? Color.lociSage.opacity(0.10) : Color.clear)
        .onHover { isHovering = $0 }
        .onTapGesture {
            handleTap()
        }
    }

    private var kindLabel: LocalizedStringKey {
        switch entry.kind {
        case .teleport: return "Teleport"
        case .navigate: return "Navigate"
        case .search:   return "Search"
        case .coord:    return "Coord"
        }
    }

    /// Re-apply the row's action. Teleport / coord / search rows
    /// teleport the iPhone again (or just fly the map if no device
    /// is selected). Navigate rows re-plan navigation with the
    /// CURRENT travel profile + speed — the row doesn't persist
    /// the original profile because the user's preference now
    /// probably differs from when the row was recorded.
    private func handleTap() {
        let coord = Coordinate(lat: entry.lat, lng: entry.lng)
        // Always fly the map so the user gets visual feedback even
        // when no device is connected (Map browse-only path).
        state.pendingMapFly = MapFlyRequest(coordinate: coord, spanMeters: 2_500)

        guard let udid = state.selectedUDID,
              udid != AppState.virtualMapUDID,
              state.devices.first(where: { $0.udid == udid })?.connected == true
        else {
            // No device — leave it at the map fly. Close so the
            // user sees what just happened.
            close()
            return
        }

        Task {
            switch entry.kind {
            case .teleport, .search, .coord:
                await state.teleport(udid: udid, lat: entry.lat, lng: entry.lng)
            case .navigate:
                let speed = state.customSpeedMps ?? state.travelProfile.defaultSpeedMps
                await state.navigate(
                    udid: udid,
                    through: [coord],
                    profile: state.travelProfile,
                    speed: speed,
                )
            }
        }
        close()
    }

    /// "5 min ago", "Today", "Yesterday", or the date. RelativeDateTime
    /// formatter handles the localisation for free.
    private func timeAgo(_ d: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: d, relativeTo: .now)
    }
}
