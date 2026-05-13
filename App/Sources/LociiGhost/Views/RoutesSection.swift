import SwiftUI
import SwiftData

/// Sidebar block listing the user's saved Routes (typically GPX
/// imports). One click on a row asks the daemon to teleport to the
/// route's first point and then navigate the rest as a straight-line
/// multi-stop trip — see `AppState.runRoute` for why straight-line.
///
/// Mirrors BookmarksSection's grouping + collapsing pattern so the
/// sidebar feels uniform: empty-string category lifts to the top,
/// section headers are click-to-collapse, newest-first within each
/// category. Empty state walks the user through Cmd-O to import.
struct RoutesSection: View {
    @Environment(AppState.self) private var state
    @Query(sort: [SortDescriptor(\Route.createdAt, order: .reverse)])
    private var routes: [Route]

    /// Per-category collapse state. Same shape as BookmarksSection.
    @State private var collapsed: Set<String> = []
    /// Whole-section collapse — title + + button stay visible so the
    /// user can still import a GPX even when the body is folded.
    @State private var sectionCollapsed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text("Routes",
                     comment: "Sidebar section header for saved GPX routes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !routes.isEmpty {
                    Text("\(routes.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: .capsule)
                }
                Spacer()
                // The + button needs to be visible AT ALL TIMES,
                // including while the section is collapsed, because
                // the empty-state hint that points at File ▸ Import
                // GPX is hidden then. Make it big enough to spot
                // and give it its own hover background.
                Button {
                    Task { @MainActor in await state.importGPX() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tint)
                        .padding(2)
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help(Text("Import GPX…",
                           comment: "Tooltip on the Routes sidebar plus button"))
                Image(systemName: sectionCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                    .hoverHighlight(cornerRadius: 4, changesCursor: false)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            sectionCollapsed.toggle()
                        }
                    }
            }

            if !sectionCollapsed {
                if routes.isEmpty {
                    emptyState
                } else {
                    ForEach(grouped, id: \.0) { (category, items) in
                        categorySection(category: category, items: items)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .foregroundStyle(.secondary)
                Text("No saved routes yet.",
                     comment: "Empty state for the Routes sidebar section")
                    .font(.callout)
            }
            Text("Use **File ▸ Import GPX…** (⌘O) to add a recorded track.",
                 comment: "Helper text under the empty routes state")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var grouped: [(String, [Route])] {
        var bins: [String: [Route]] = [:]
        for r in routes {
            bins[r.category, default: []].append(r)
        }
        return bins
            .sorted { (a, b) in
                if a.key.isEmpty { return true }
                if b.key.isEmpty { return false }
                return a.key.localizedStandardCompare(b.key) == .orderedAscending
            }
    }

    @ViewBuilder
    private func categorySection(category: String, items: [Route]) -> some View {
        let key = category
        let isCollapsed = collapsed.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(category.isEmpty
                     ? String(localized: "Uncategorized",
                              comment: "Header for routes with no category set")
                     : category)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(items.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .hoverHighlight(cornerRadius: 4, changesCursor: false)
            .onTapGesture {
                if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
            }

            if !isCollapsed {
                ForEach(items) { r in
                    RouteRow(route: r)
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct RouteRow: View {
    let route: Route
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: route.iconSymbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(route.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(String(
                    format: String(
                        localized: "%lld points",
                        comment: "RouteRow subtitle — total saved coords",
                    ),
                    route.pointCount,
                ))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .hoverHighlight(cornerRadius: 5, changesCursor: false)
        .onTapGesture {
            // Click → ask first. A route can be hundreds of points
            // long; a stray click that immediately yanks the iPhone
            // away from where it currently sits would be very
            // annoying. We park the route in `routePendingConfirm`
            // and let the alert in MainView do the actual run on
            // user confirmation.
            guard let udid = state.selectedUDID,
                  state.devices.first(where: { $0.udid == udid })?.connected == true
            else {
                state.lastError = String(localized: "Connect a device first.")
                return
            }
            state.routePendingConfirm = route
        }
        .contextMenu {
            Button {
                guard state.selectedUDID != nil else { return }
                state.routePendingConfirm = route
            } label: {
                Label("Start route",
                      systemImage: "play.fill")
            }
            Button {
                state.editingRoute = route
            } label: {
                Label("Edit…",
                      systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                state.deleteRoute(route)
            } label: {
                Label("Delete",
                      systemImage: "trash")
            }
        }
    }
}
