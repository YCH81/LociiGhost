import SwiftUI
import SwiftData

/// Sidebar block listing user-saved bookmarks. Click a row to teleport
/// the connected iPhone to that point. Categories collapse so a
/// power-user with 30 entries doesn't fill the sidebar.
///
/// Empty state walks the user through adding their first one (right-
/// click the map). After that, this section just lists them.
struct BookmarksSection: View {
    @Environment(AppState.self) private var state
    @Query(sort: [SortDescriptor(\Bookmark.createdAt, order: .reverse)])
    private var bookmarks: [Bookmark]

    /// Per-category EXPAND state. Keyed by category string;
    /// uncategorised bookmarks live under the empty-string key.
    /// We track expanded-rather-than-collapsed so the default
    /// (empty set) means "everything collapsed" — categories
    /// only show their bookmark rows after the user explicitly
    /// clicks the chevron. This matches the section-level
    /// collapse default and lets a power user with 70+ imported
    /// bookmarks open just the one folder they want.
    @State private var expanded: Set<String> = []
    /// Whole-section collapse. Title row stays visible so the user
    /// can find the section to expand again; only the body folds.
    /// Defaults to `true` (collapsed) on launch — the bookmark
    /// list grows fast for power users (the LocWarp JSON imports
    /// 70+ entries in one go) and a sidebar full of expanded
    /// bookmarks crowds out everything else. The user expands
    /// when they actually want to teleport.
    @State private var sectionCollapsed: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text("Bookmarks",
                     comment: "Sidebar section header for saved locations")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !bookmarks.isEmpty {
                    Text("\(bookmarks.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: .capsule)
                }
                Spacer()
                // v1.9: only the quick Import shortcut remains here.
                // Export + Bulk paste have moved to Settings (Cmd-,)
                // alongside the other less-frequent actions (Google
                // API key, logs folder, alert sound). Keeping Import
                // inline is intentional — it's the action a user
                // expects to reach in one click when they're already
                // looking at the (empty) Bookmarks panel.
                Button {
                    Task { @MainActor in await state.importBookmarksJSON() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tint)
                        .padding(2)
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help(Text("Import bookmarks from JSON (export + bulk paste live in Settings — Cmd-,)",
                           comment: "Tooltip on the Bookmarks sidebar plus button"))
                Image(systemName: sectionCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .contentShape(.rect)
            .hoverHighlight(cornerRadius: 4, changesCursor: false)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sectionCollapsed.toggle()
                }
            }

            if !sectionCollapsed {
                if bookmarks.isEmpty {
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
                Image(systemName: "bookmark")
                    .foregroundStyle(.secondary)
                Text("No bookmarks yet.",
                     comment: "Empty state for the Bookmarks sidebar section")
                    .font(.callout)
            }
            Text("Right-click anywhere on the map and pick **Save as bookmark…** to add one.",
                 comment: "Helper text under the empty bookmarks state")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bookmarks grouped by `category`, with the empty-string
    /// category returned first ("Uncategorized" header). Within
    /// each category, newest-first (matches the `@Query` sort order).
    private var grouped: [(String, [Bookmark])] {
        var bins: [String: [Bookmark]] = [:]
        for b in bookmarks {
            bins[b.category, default: []].append(b)
        }
        // Empty category first, then alphabetical.
        return bins
            .sorted { (a, b) in
                if a.key.isEmpty { return true }
                if b.key.isEmpty { return false }
                return a.key.localizedStandardCompare(b.key) == .orderedAscending
            }
    }

    @ViewBuilder
    private func categorySection(category: String, items: [Bookmark]) -> some View {
        let key = category
        let isExpanded = expanded.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(category.isEmpty
                     ? String(localized: "Uncategorized",
                              comment: "Header for bookmarks with no category set")
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
                if isExpanded { expanded.remove(key) } else { expanded.insert(key) }
            }

            if isExpanded {
                ForEach(items) { bm in
                    BookmarkRow(bookmark: bm)
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bookmark.iconSymbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(String(format: "%.5f, %.5f", bookmark.lat, bookmark.lng))
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
            // Click → teleport (most common intent). Disabled with
            // a toast if no device is connected; better UX than
            // silently doing nothing.
            guard let udid = state.selectedUDID,
                  state.devices.first(where: { $0.udid == udid })?.connected == true
            else {
                state.lastError = String(localized: "Connect a device first.")
                return
            }
            // Fly the desktop map to the bookmark's location too —
            // teleport alone moves the iPhone-simulated pin but
            // leaves the camera where it was, which is jarring
            // when the user clicks a bookmark across the world.
            // 2 km span is wide enough to see surrounding context
            // without zooming the puck into a dot.
            state.pendingMapFly = MapFlyRequest(
                coordinate: Coordinate(lat: bookmark.lat, lng: bookmark.lng),
                spanMeters: 2_000,
            )
            Task {
                await state.teleport(udid: udid,
                                     lat: bookmark.lat, lng: bookmark.lng)
            }
        }
        .contextMenu {
            Button {
                state.editingBookmark = bookmark
            } label: {
                Label("Edit…",
                      systemImage: "pencil")
            }
            Button {
                guard let udid = state.selectedUDID else { return }
                state.pendingMapFly = MapFlyRequest(
                    coordinate: Coordinate(lat: bookmark.lat, lng: bookmark.lng),
                    spanMeters: 2_000,
                )
                Task {
                    await state.teleport(udid: udid,
                                         lat: bookmark.lat, lng: bookmark.lng)
                }
            } label: {
                Label("Teleport here",
                      systemImage: "wand.and.stars")
            }
            Divider()
            Button(role: .destructive) {
                state.deleteBookmark(bookmark)
            } label: {
                Label("Delete",
                      systemImage: "trash")
            }
        }
    }
}
