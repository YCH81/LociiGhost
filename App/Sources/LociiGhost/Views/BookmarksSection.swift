import SwiftUI
import SwiftData

// MARK: - Sort mode

private enum BookmarkSortMode: String, CaseIterable {
    /// Newest first — the @Query default, no extra cost.
    case date   = "date"
    /// A → Z by name, case-insensitive locale-aware.
    case alpha  = "alpha"
    /// User-defined drag order; persisted via Bookmark.sortOrder.
    case manual = "manual"
}

// MARK: - Drag payload (manual reorder)

/// Transferable token for same-session drag-to-reorder.
/// Carries the PersistentIdentifier's hash — stable for the process
/// lifetime, never written to disk.
private struct BookmarkDragPayload: Codable, Transferable {
    let idHash: Int
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// MARK: - Section

/// Sidebar block listing user-saved bookmarks. Click a row to teleport
/// the connected iPhone to that point. Categories collapse so a
/// power-user with 30 entries doesn't fill the sidebar.
///
/// v1.11.2: three sort modes (date / alpha / manual) persisted via
/// @AppStorage. Manual mode shows drag handles and supports
/// drag-to-reorder within each category section. Switching to manual
/// seeds Bookmark.sortOrder from the current visual order so the list
/// doesn't jump.
///
/// Perf notes:
/// • No @Environment(\.modelContext) — adding it registers the view in
///   SwiftData's context notification group, causing spurious re-renders
///   on any SwiftData write. sortOrder mutations on @Model objects are
///   auto-tracked and auto-saved by SwiftData without explicit save().
/// • ForEach uses the SwiftData-optimised Identifiable form (not the
///   Array(enumerated()) pattern) to preserve SwiftData's diff optimisation.
struct BookmarksSection: View {
    @Environment(AppState.self) private var state
    /// Newest-first from the query; re-sorted in `grouped` when the
    /// active sort mode isn't `.date`.
    @Query(sort: [SortDescriptor(\Bookmark.createdAt, order: .reverse)])
    private var bookmarks: [Bookmark]

    @State private var expanded: Set<String> = []
    @State private var sectionCollapsed: Bool = true
    /// Hash of the bookmark currently targeted as a drop destination
    /// in manual mode (drives the highlight background).
    @State private var draggingHash: Int?

    private var sortMode: BookmarkSortMode {
        BookmarkSortMode(rawValue: state.bookmarkSortMode) ?? .date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
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

    // MARK: - Header

    private var headerRow: some View {
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
            if !bookmarks.isEmpty {
                sortMenuButton
            }
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
    }

    private var sortMenuButton: some View {
        Menu {
            Picker(
                String(localized: "Sort order",
                       comment: "Bookmarks sort-order picker label"),
                selection: Binding(
                    get: { sortMode },
                    set: { setSortMode($0) }
                )
            ) {
                Label {
                    Text("By date added",
                         comment: "Bookmarks sort option — newest first")
                } icon: {
                    Image(systemName: "clock")
                }
                .tag(BookmarkSortMode.date)

                Label {
                    Text("By name (A–Z)",
                         comment: "Bookmarks sort option — alphabetical")
                } icon: {
                    Image(systemName: "textformat.abc")
                }
                .tag(BookmarkSortMode.alpha)

                Label {
                    Text("Manual order",
                         comment: "Bookmarks sort option — drag-to-reorder")
                } icon: {
                    Image(systemName: "hand.draw")
                }
                .tag(BookmarkSortMode.manual)
            }
        } label: {
            Image(systemName: sortIconName)
                .font(.caption)
                .foregroundStyle(sortMode == .date ? Color.secondary : Color.accentColor)
                .padding(2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Sort order",
                   comment: "Tooltip for the bookmarks sort-order menu button"))
    }

    private var sortIconName: String {
        switch sortMode {
        case .date:   return "arrow.up.arrow.down"
        case .alpha:  return "textformat.abc"
        case .manual: return "hand.draw"
        }
    }

    // MARK: - Empty state

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

    // MARK: - Grouping + sort

    private var grouped: [(String, [Bookmark])] {
        var bins: [String: [Bookmark]] = [:]
        for b in bookmarks { bins[b.category, default: []].append(b) }
        return bins
            .sorted { a, b in
                if a.key.isEmpty { return true }
                if b.key.isEmpty { return false }
                return a.key.localizedStandardCompare(b.key) == .orderedAscending
            }
            .map { (cat, items) in (cat, sortItems(items)) }
    }

    private func sortItems(_ items: [Bookmark]) -> [Bookmark] {
        switch sortMode {
        case .date:
            return items                // already newest-first from @Query
        case .alpha:
            return items.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .manual:
            return items.sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    // MARK: - Category section

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
                // SwiftData-native ForEach — uses Bookmark's Identifiable
                // conformance (PersistentIdentifier) directly. Avoids the
                // Array(enumerated()) intermediate allocation and preserves
                // SwiftData's internal diff optimisation.
                ForEach(items) { bm in
                    rowView(bm, in: items, category: category)
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func rowView(
        _ bm: Bookmark,
        in items: [Bookmark],
        category: String
    ) -> some View {
        if sortMode == .manual {
            BookmarkRow(bookmark: bm, showDragHandle: true)
                .background(
                    draggingHash == bm.persistentModelID.hashValue
                        ? AnyShapeStyle(Color.lociSage.opacity(0.18))
                        : AnyShapeStyle(Color.clear),
                    in: .rect(cornerRadius: 4)
                )
                .draggable(BookmarkDragPayload(idHash: bm.persistentModelID.hashValue)) {
                    Text(bm.name)
                        .font(.caption2)
                        .padding(6)
                        .background(.regularMaterial, in: .rect(cornerRadius: 4))
                }
                .dropDestination(for: BookmarkDragPayload.self) { payloads, _ in
                    guard let p = payloads.first else { return false }
                    reorder(in: category, items: items,
                            sourceHash: p.idHash, beforeHash: bm.persistentModelID.hashValue)
                    draggingHash = nil
                    return true
                } isTargeted: { targeting in
                    draggingHash = targeting ? bm.persistentModelID.hashValue : nil
                }
        } else {
            BookmarkRow(bookmark: bm, showDragHandle: false)
        }
    }

    // MARK: - Sort mode change

    private func setSortMode(_ mode: BookmarkSortMode) {
        guard mode != sortMode else { return }
        if mode == .manual {
            // Seed sortOrder from the current visual order so the list
            // doesn't jump when the user first enables manual mode.
            // Mutating @Model properties is auto-tracked by SwiftData;
            // no explicit save() call needed.
            let snapshot = grouped          // still sorted by old mode
            for (_, items) in snapshot {
                for (idx, bm) in items.enumerated() {
                    bm.sortOrder = idx
                }
            }
        }
        state.bookmarkSortMode = mode.rawValue
    }

    // MARK: - Reorder (manual mode)

    /// Move the bookmark identified by `sourceHash` to just before the
    /// bookmark identified by `beforeHash`, then reassign `sortOrder`
    /// to reflect the new sequence.
    ///
    /// Uses `Array.move(fromOffsets:toOffset:)` which handles all the
    /// insertion-index edge cases correctly.
    private func reorder(
        in category: String,
        items: [Bookmark],
        sourceHash: Int,
        beforeHash: Int
    ) {
        var mutable = items
        guard
            let srcIdx = mutable.firstIndex(where: { $0.persistentModelID.hashValue == sourceHash }),
            let tgtIdx = mutable.firstIndex(where: { $0.persistentModelID.hashValue == beforeHash }),
            srcIdx != tgtIdx
        else { return }
        // move(fromOffsets:toOffset:) inserts *before* toOffset after
        // removing the source, so "insert before target" is just tgtIdx
        // when src < tgt, and tgtIdx when src > tgt (no shift needed).
        let insertAt = tgtIdx > srcIdx ? tgtIdx + 1 : tgtIdx
        mutable.move(fromOffsets: IndexSet(integer: srcIdx), toOffset: insertAt)
        for (i, b) in mutable.enumerated() { b.sortOrder = i }
        // SwiftData auto-saves @Model property mutations on the next runloop.
    }
}

// MARK: - Row

private struct BookmarkRow: View {
    let bookmark: Bookmark
    /// When true, prepends a drag-handle glyph. Only set in manual mode.
    var showDragHandle: Bool = false
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            if showDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
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
            guard let udid = state.selectedUDID,
                  state.devices.first(where: { $0.udid == udid })?.connected == true
            else {
                state.lastError = String(localized: "Connect a device first.")
                return
            }
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
                Label("Edit…", systemImage: "pencil")
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
                Label("Teleport here", systemImage: "wand.and.stars")
            }
            Divider()
            Button(role: .destructive) {
                state.deleteBookmark(bookmark)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
