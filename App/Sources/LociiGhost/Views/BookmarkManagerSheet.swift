import SwiftUI
import SwiftData

/// Power-user management surface for the bookmarks store.
///
/// Two tabs:
///   • Bookmarks — multi-select list with bulk delete / move / prefix-suffix rename.
///   • Categories — rename / delete-with-bookmarks / delete-keep-bookmarks / merge.
///
/// All mutations go through dedicated `AppState` methods so the SwiftData
/// save semantics stay consistent with the sidebar's single-row paths.
/// The sheet keeps zero source-of-truth state — selection is the only
/// transient piece, and it's reconciled against the live `@Query`
/// result each render so deletes don't leave stale ids behind.
struct BookmarkManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Query(sort: [SortDescriptor(\Bookmark.createdAt, order: .reverse)])
    private var bookmarks: [Bookmark]

    private enum Tab: String, CaseIterable, Identifiable {
        case bookmarks, categories
        var id: String { rawValue }
    }
    @State private var tab: Tab = .bookmarks

    // Bookmarks-tab state
    @State private var search: String = ""
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var bulkSheet: BulkSheetKind?
    private enum BulkSheetKind: Identifiable {
        case move, prefix, suffix
        var id: String {
            switch self {
            case .move: return "move"
            case .prefix: return "prefix"
            case .suffix: return "suffix"
            }
        }
    }
    @State private var confirmBulkDelete: Bool = false

    // Categories-tab state
    @State private var categorySheet: CategorySheetKind?
    private struct CategorySheetKind: Identifiable {
        enum Op { case rename, deleteWithBookmarks, deleteKeepBookmarks, merge }
        let op: Op
        let category: String
        var id: String { "\(op)-\(category)" }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                Text("Bookmarks", comment: "Manage sheet tab — bookmark list")
                    .tag(Tab.bookmarks)
                Text("Categories", comment: "Manage sheet tab — category list")
                    .tag(Tab.categories)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Group {
                switch tab {
                case .bookmarks:  bookmarksTab
                case .categories: categoriesTab
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 880, maxWidth: 1100,
               minHeight: 480, idealHeight: 600, maxHeight: 900)
        .sheet(item: $bulkSheet) { kind in
            bulkSheetView(kind)
        }
        .sheet(item: $categorySheet) { spec in
            categorySheetView(spec)
        }
        .alert(
            Text("Delete \(selectedBookmarks.count) bookmark\(selectedBookmarks.count == 1 ? "" : "s")?",
                 comment: "Confirmation title for bulk-delete in manage sheet"),
            isPresented: $confirmBulkDelete
        ) {
            Button(role: .destructive) {
                state.bulkDeleteBookmarks(selectedBookmarks)
                selection.removeAll()
            } label: {
                Text("Delete", comment: "Destructive confirm button for bulk delete")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Cancel button")
            }
        } message: {
            Text("This can't be undone.",
                 comment: "Bulk-delete confirmation body")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(.tint)
            Text("Manage bookmarks",
                 comment: "Title of the bookmark management sheet")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Derived data

    private var filteredBookmarks: [Bookmark] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return bookmarks }
        return bookmarks.filter {
            $0.name.lowercased().contains(q) ||
            $0.category.lowercased().contains(q)
        }
    }

    /// Bookmark instances currently checked. Reconciled against the
    /// live @Query so a delete-then-act flow can't operate on tombstones.
    private var selectedBookmarks: [Bookmark] {
        let set = selection
        return bookmarks.filter { set.contains($0.persistentModelID) }
    }

    /// Categories grouped with counts and a stable display name.
    /// "" maps to "Uncategorized" but keeps its empty raw key for ops.
    private struct CategoryBin: Identifiable {
        let raw: String
        let display: String
        let count: Int
        var id: String { raw }
        var isUncategorized: Bool { raw.isEmpty }
    }
    private var categoryBins: [CategoryBin] {
        var counts: [String: Int] = [:]
        for b in bookmarks { counts[b.category, default: 0] += 1 }
        return counts
            .sorted { a, b in
                if a.key.isEmpty { return true }
                if b.key.isEmpty { return false }
                return a.key.localizedStandardCompare(b.key) == .orderedAscending
            }
            .map { (raw, n) in
                CategoryBin(
                    raw: raw,
                    display: raw.isEmpty
                        ? String(localized: "Uncategorized",
                                 comment: "Display label for the empty-category bin")
                        : raw,
                    count: n,
                )
            }
    }

    private var allCategoryNames: [String] {
        categoryBins.filter { !$0.isUncategorized }.map(\.raw)
    }

    // MARK: - Bookmarks tab

    private var bookmarksTab: some View {
        VStack(spacing: 0) {
            bookmarksToolbar
            Divider()
            if filteredBookmarks.isEmpty {
                emptyState
            } else {
                bookmarksList
            }
            Divider()
            bookmarksActionBar
        }
    }

    private var bookmarksToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(
                String(localized: "Search by name or category",
                       comment: "Manage sheet bookmark filter placeholder"),
                text: $search,
            )
            .textFieldStyle(.roundedBorder)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 12)
            Toggle(isOn: Binding(
                get: { !filteredBookmarks.isEmpty &&
                       filteredBookmarks.allSatisfy { selection.contains($0.persistentModelID) } },
                set: { on in
                    let ids = filteredBookmarks.map(\.persistentModelID)
                    if on { selection.formUnion(ids) }
                    else  { selection.subtract(ids) }
                }
            )) {
                Text("Select all",
                     comment: "Toggle to select every visible bookmark")
            }
            .toggleStyle(.checkbox)
            Text(selection.isEmpty
                 ? String(localized: "\(filteredBookmarks.count) bookmarks",
                          comment: "Footer count when nothing is selected")
                 : String(localized: "\(selection.count) selected",
                          comment: "Footer count when at least one row is selected"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 100, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var bookmarksList: some View {
        List(filteredBookmarks, selection: $selection) { bm in
            HStack(spacing: 10) {
                Image(systemName: bm.iconSymbol)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bm.name)
                        .lineLimit(1)
                    Text(String(format: "%.5f, %.5f", bm.lat, bm.lng))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if bm.imageURL != nil {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(bm.category.isEmpty
                     ? String(localized: "Uncategorized",
                              comment: "Category badge for the empty bin")
                     : bm.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: .capsule)
            }
            .tag(bm.persistentModelID)
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(search.isEmpty
                 ? String(localized: "No bookmarks yet.",
                          comment: "Manage sheet empty state — store is empty")
                 : String(localized: "No matches.",
                          comment: "Manage sheet empty state — search has no hits"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.02))
    }

    private var bookmarksActionBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    bulkSheet = .move
                } label: {
                    Label {
                        Text("Move to category…",
                             comment: "Bulk action — assign selected bookmarks to a category")
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                Button {
                    bulkSheet = .prefix
                } label: {
                    Label {
                        Text("Add prefix to names…",
                             comment: "Bulk action — prepend text to every selected name")
                    } icon: {
                        Image(systemName: "text.insert")
                    }
                }
                Button {
                    bulkSheet = .suffix
                } label: {
                    Label {
                        Text("Add suffix to names…",
                             comment: "Bulk action — append text to every selected name")
                    } icon: {
                        Image(systemName: "text.append")
                    }
                }
            } label: {
                Label {
                    Text("Bulk actions",
                         comment: "Menu button label for batch bookmark operations")
                } icon: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(selection.isEmpty)

            Spacer()

            Button(role: .destructive) {
                confirmBulkDelete = true
            } label: {
                Label {
                    Text("Delete selected",
                         comment: "Destructive button — delete every selected bookmark")
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Categories tab

    private var categoriesTab: some View {
        VStack(spacing: 0) {
            if categoryBins.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No categories yet.",
                         comment: "Manage sheet empty state for the categories tab")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(categoryBins) { bin in
                    HStack(spacing: 8) {
                        Image(systemName: bin.isUncategorized ? "tray" : "folder.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        Text(bin.display)
                        Text("\(bin.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: .capsule)
                        Spacer()
                        categoryRowMenu(bin)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func categoryRowMenu(_ bin: CategoryBin) -> some View {
        Menu {
            if !bin.isUncategorized {
                Button {
                    categorySheet = .init(op: .rename, category: bin.raw)
                } label: {
                    Label {
                        Text("Rename…",
                             comment: "Category menu — rename action")
                    } icon: {
                        Image(systemName: "pencil")
                    }
                }
                if allCategoryNames.count >= 2 {
                    Menu {
                        ForEach(allCategoryNames.filter { $0 != bin.raw }, id: \.self) { other in
                            Button {
                                state.mergeCategory(bin.raw, into: other)
                            } label: {
                                Text(other)
                            }
                        }
                    } label: {
                        Label {
                            Text("Merge into",
                                 comment: "Category menu — submenu picking a merge target")
                        } icon: {
                            Image(systemName: "arrow.triangle.merge")
                        }
                    }
                }
                Divider()
                Button {
                    categorySheet = .init(op: .deleteKeepBookmarks, category: bin.raw)
                } label: {
                    Label {
                        Text("Delete category (keep bookmarks)",
                             comment: "Category menu — clear the label but retain rows")
                    } icon: {
                        Image(systemName: "folder.badge.minus")
                    }
                }
                Button(role: .destructive) {
                    categorySheet = .init(op: .deleteWithBookmarks, category: bin.raw)
                } label: {
                    Label {
                        Text("Delete category and its bookmarks",
                             comment: "Category menu — destructive delete with rows")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            } else {
                Text("Uncategorized can't be renamed or merged.",
                     comment: "Disabled-menu hint for the empty-category bin")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Bulk sheets

    @ViewBuilder
    private func bulkSheetView(_ kind: BulkSheetKind) -> some View {
        switch kind {
        case .move:
            BulkMoveSheet(
                selectionCount: selectedBookmarks.count,
                existingCategories: allCategoryNames,
            ) { newCategory in
                state.bulkMoveBookmarks(selectedBookmarks, to: newCategory)
                selection.removeAll()
            }
        case .prefix:
            BulkAffixSheet(kind: .prefix, selectionCount: selectedBookmarks.count) { text in
                state.bulkRenameBookmarks(selectedBookmarks, prefix: text)
            }
        case .suffix:
            BulkAffixSheet(kind: .suffix, selectionCount: selectedBookmarks.count) { text in
                state.bulkRenameBookmarks(selectedBookmarks, suffix: text)
            }
        }
    }

    @ViewBuilder
    private func categorySheetView(_ spec: CategorySheetKind) -> some View {
        switch spec.op {
        case .rename:
            CategoryRenameSheet(current: spec.category) { newName in
                state.renameCategory(from: spec.category, to: newName)
            }
        case .deleteWithBookmarks:
            CategoryDeleteConfirmSheet(
                category: spec.category,
                count: categoryBins.first(where: { $0.raw == spec.category })?.count ?? 0,
                mode: .deleteBookmarks,
            ) {
                state.deleteCategoryWithBookmarks(spec.category)
            }
        case .deleteKeepBookmarks:
            CategoryDeleteConfirmSheet(
                category: spec.category,
                count: categoryBins.first(where: { $0.raw == spec.category })?.count ?? 0,
                mode: .keepBookmarks,
            ) {
                state.deleteCategoryKeepingBookmarks(spec.category)
            }
        case .merge:
            EmptyView()  // unused — merge happens directly via menu
        }
    }
}

// MARK: - Sub-sheets

/// Pick a destination category for the selected bookmarks. Includes a
/// "(uncategorized)" choice and a "create new…" inline text field.
private struct BulkMoveSheet: View {
    let selectionCount: Int
    let existingCategories: [String]
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: String? = nil
    @State private var newCategory: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(selectionCount) bookmark\(selectionCount == 1 ? "" : "s") to…",
                 comment: "Title of the bulk-move category picker sheet")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    optionRow(
                        label: String(localized: "Uncategorized",
                                      comment: "Move target — clear the category label"),
                        value: "",
                        systemImage: "tray",
                    )
                    ForEach(existingCategories, id: \.self) { c in
                        optionRow(label: c, value: c, systemImage: "folder.fill")
                    }
                }
            }
            .frame(maxHeight: 260)
            Divider()
            HStack(spacing: 8) {
                Text("New category:",
                     comment: "Label preceding the new-category text field")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "Name…",
                           comment: "Placeholder for new-category text field"),
                    text: $newCategory,
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitNew() }
            }
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Cancel button")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    commit()
                } label: {
                    Text("Move", comment: "Confirm button for bulk-move sheet")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil && newCategory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 420)
    }

    @ViewBuilder
    private func optionRow(label: String, value: String, systemImage: String) -> some View {
        Button {
            picked = value
            newCategory = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: picked == value
                      ? "largecircle.fill.circle"
                      : "circle")
                    .foregroundStyle(picked == value ? Color.accentColor : Color.secondary)
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(label)
                Spacer()
            }
            .contentShape(.rect)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        let typed = newCategory.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            onCommit(typed)
        } else if let p = picked {
            onCommit(p)
        }
        dismiss()
    }

    private func commitNew() {
        let typed = newCategory.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        onCommit(typed)
        dismiss()
    }
}

/// Single-field text sheet for adding a prefix or suffix to every
/// selected bookmark name.
private struct BulkAffixSheet: View {
    enum Kind { case prefix, suffix }
    let kind: Kind
    let selectionCount: Int
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .prefix
                 ? String(localized: "Add prefix to \(selectionCount) name\(selectionCount == 1 ? "" : "s")",
                          comment: "Bulk-rename sheet title for adding a prefix")
                 : String(localized: "Add suffix to \(selectionCount) name\(selectionCount == 1 ? "" : "s")",
                          comment: "Bulk-rename sheet title for adding a suffix"))
                .font(.headline)
            TextField(
                kind == .prefix
                    ? String(localized: "Prefix (e.g. [Tokyo] )",
                             comment: "Placeholder for prefix text field")
                    : String(localized: "Suffix (e.g.  · favorite)",
                             comment: "Placeholder for suffix text field"),
                text: $text,
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { commit() }
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Cancel button")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    commit()
                } label: {
                    Text("Apply",
                         comment: "Confirm button for bulk-rename sheet")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 420)
    }

    private func commit() {
        let v = text
        guard !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCommit(v)
        dismiss()
    }
}

/// Rename a category by typing the new label.
private struct CategoryRenameSheet: View {
    let current: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename category",
                 comment: "Title of the category-rename sheet")
                .font(.headline)
            Text("Currently: \(current)",
                 comment: "Subhead showing the current category name being renamed")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "New name",
                       comment: "Placeholder for the category-rename text field"),
                text: $text,
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { commit() }
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Cancel button")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    commit()
                } label: {
                    Text("Rename",
                         comment: "Confirm button for category-rename sheet")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty ||
                          text.trimmingCharacters(in: .whitespaces) == current)
            }
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 420)
        .onAppear { text = current }
    }

    private func commit() {
        let v = text.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != current else { return }
        onCommit(v)
        dismiss()
    }
}

/// Confirmation sheet for both delete-category modes. Different copy
/// per mode so the user sees exactly what's about to happen.
private struct CategoryDeleteConfirmSheet: View {
    enum Mode { case deleteBookmarks, keepBookmarks }
    let category: String
    let count: Int
    let mode: Mode
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .deleteBookmarks
                 ? String(localized: "Delete category and \(count) bookmark\(count == 1 ? "" : "s")?",
                          comment: "Title for destructive delete-with-bookmarks confirmation")
                 : String(localized: "Clear category from \(count) bookmark\(count == 1 ? "" : "s")?",
                          comment: "Title for delete-keep-bookmarks confirmation"))
                .font(.headline)
            Text(mode == .deleteBookmarks
                 ? String(localized: "“\(category)” and every bookmark inside it will be removed. This can't be undone.",
                          comment: "Body text for destructive delete-with-bookmarks confirmation")
                 : String(localized: "“\(category)” will be removed and its bookmarks will move to Uncategorized.",
                          comment: "Body text for delete-keep-bookmarks confirmation"))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Cancel button")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: mode == .deleteBookmarks ? .destructive : nil) {
                    onConfirm()
                    dismiss()
                } label: {
                    Text(mode == .deleteBookmarks
                         ? String(localized: "Delete all",
                                  comment: "Destructive confirm — delete category and bookmarks")
                         : String(localized: "Clear category",
                                  comment: "Confirm — clear label, keep bookmarks"))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 380, idealWidth: 440)
    }
}
