import AppKit
import CoreLocation
import Foundation
import SwiftData
import Observation
import SwiftUI
import UniformTypeIdentifiers
import LociiGhostCore

// v1.15.2 audit (P12/Phase 7): split out of AppState.swift, which had
// reached 5449 lines across 37 MARK sections. These are extensions
// rather than separate types on purpose: every one of these methods
// reads or writes AppState's own SwiftData context and error surface,
// so extracting real types would mean deciding ownership of a dozen
// shared stored properties — a design change, not a refactor, and not
// one to make in the same pass as sixty bug fixes. The file boundary
// is what was actually costing time when navigating the class.

// Bookmarks CRUD, bulk and category operations, recent places, and
// the bookmarks JSON / bulk-paste paths.

extension AppState {
    // MARK: - Bookmarks (Phase 5.3)

    /// Add a new bookmark. The sidebar's `@Query<Bookmark>` re-runs
    /// automatically on insert, so the new entry appears without
    /// further plumbing.
    func addBookmark(name: String, lat: Double, lng: Double,
                     category: String = "",
                     iconSymbol: String = "mappin.circle.fill",
                     imageURL: String? = nil) {
        guard let ctx = modelContext else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameToSave = trimmed.isEmpty
            ? String(format: "(%.5f, %.5f)", lat, lng)
            : trimmed
        let imgTrimmed = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgToSave = (imgTrimmed?.isEmpty ?? true) ? nil : imgTrimmed
        let bm = Bookmark(name: nameToSave, lat: lat, lng: lng,
                          category: category.trimmingCharacters(in: .whitespaces),
                          iconSymbol: iconSymbol,
                          imageURL: imgToSave)
        ctx.insert(bm)
        try? ctx.save()
        bookmarksRevision &+= 1
    }

    /// Delete a bookmark. Save explicitly so the on-disk store
    /// reflects the deletion immediately — relying on SwiftData's
    /// debounced auto-save means a quick app quit could lose it.
    func deleteBookmark(_ bm: Bookmark) {
        guard let ctx = modelContext else { return }
        ctx.delete(bm)
        try? ctx.save()
        bookmarksRevision &+= 1
    }

    /// Rename / re-categorise / re-icon. Phase 5.3 keeps the edit
    /// affordance simple — one method, all fields optional.
    func updateBookmark(_ bm: Bookmark,
                        name: String? = nil,
                        category: String? = nil,
                        iconSymbol: String? = nil) {
        guard let ctx = modelContext else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { bm.name = trimmed }
        }
        if let category {
            bm.category = category.trimmingCharacters(in: .whitespaces)
        }
        if let iconSymbol, !iconSymbol.isEmpty {
            bm.iconSymbol = iconSymbol
        }
        try? ctx.save()
        bookmarksRevision &+= 1
    }

    // MARK: - Bookmarks bulk + category operations

    /// Delete every bookmark in `bookmarks` in one save. Safe to call
    /// with an empty array (no-op). Used by the manager sheet's
    /// multi-select delete action.
    func bulkDeleteBookmarks(_ bookmarks: [Bookmark]) {
        guard let ctx = modelContext, !bookmarks.isEmpty else { return }
        for bm in bookmarks { ctx.delete(bm) }
        try? ctx.save()
        bookmarksRevision &+= 1
    }

    /// Reassign every bookmark in `bookmarks` to `category`. Empty
    /// string moves them to the Uncategorized bin. One save at the end
    /// — SwiftData batches the diff internally.
    func bulkMoveBookmarks(_ bookmarks: [Bookmark], to category: String) {
        guard let ctx = modelContext, !bookmarks.isEmpty else { return }
        let trimmed = category.trimmingCharacters(in: .whitespaces)
        for bm in bookmarks { bm.category = trimmed }
        try? ctx.save()
        bookmarksRevision &+= 1
    }

    /// Apply `prefix` and / or `suffix` to every bookmark's name.
    /// Either argument may be empty. Names that would become empty
    /// after trimming are left as-is so we don't accidentally erase
    /// a row's identity.
    func bulkRenameBookmarks(_ bookmarks: [Bookmark],
                             prefix: String = "",
                             suffix: String = "") {
        guard let ctx = modelContext, !bookmarks.isEmpty,
              !(prefix.isEmpty && suffix.isEmpty)
        else { return }
        for bm in bookmarks {
            let newName = "\(prefix)\(bm.name)\(suffix)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty { bm.name = newName }
        }
        try? ctx.save()
        bookmarksRevision &+= 1
    }

    /// Rename a category across every bookmark that currently uses it.
    /// `from` is the exact existing category string (case-sensitive).
    /// `to` is trimmed; renaming to "" effectively moves all those
    /// bookmarks to Uncategorized. Returns the count of rows updated.
    @discardableResult
    func renameCategory(from oldName: String, to newName: String) -> Int {
        guard let ctx = modelContext else { return 0 }
        let target = newName.trimmingCharacters(in: .whitespaces)
        if target == oldName { return 0 }
        let predicate = #Predicate<Bookmark> { $0.category == oldName }
        let descriptor = FetchDescriptor<Bookmark>(predicate: predicate)
        guard let matches = try? ctx.fetch(descriptor), !matches.isEmpty else { return 0 }
        for bm in matches { bm.category = target }
        try? ctx.save()
        bookmarksRevision &+= 1
        return matches.count
    }

    /// Delete every bookmark that currently belongs to `category`.
    /// Use this when the user picks "delete category and its bookmarks"
    /// from the manager sheet. Returns the count of rows removed.
    @discardableResult
    func deleteCategoryWithBookmarks(_ category: String) -> Int {
        guard let ctx = modelContext else { return 0 }
        let predicate = #Predicate<Bookmark> { $0.category == category }
        let descriptor = FetchDescriptor<Bookmark>(predicate: predicate)
        guard let matches = try? ctx.fetch(descriptor), !matches.isEmpty else { return 0 }
        for bm in matches { ctx.delete(bm) }
        try? ctx.save()
        bookmarksRevision &+= 1
        return matches.count
    }

    /// Clear `category` from every matching bookmark, leaving the
    /// records intact (they land in the Uncategorized bin). Returns
    /// the count of rows updated.
    @discardableResult
    func deleteCategoryKeepingBookmarks(_ category: String) -> Int {
        return renameCategory(from: category, to: "")
    }

    /// Merge `source` into `destination`: every bookmark that was in
    /// `source` becomes a bookmark in `destination`. A degenerate merge
    /// (same name) is a no-op. Returns the count of rows updated.
    @discardableResult
    func mergeCategory(_ source: String, into destination: String) -> Int {
        return renameCategory(from: source, to: destination)
    }

    // MARK: - Recent Places (v1.9 — history capsule on map)

    /// Hard cap on persisted RecentPlace rows. The popover renders a
    /// scroll-less list, so the cap also bounds the visual height —
    /// 50 fits "stuff I jumped to in the last week" without ever
    /// needing the user to wade through hundreds of entries. We prune
    /// the oldest beyond this on every insert.
    private static let recentPlacesCap = 50

    /// Fetch the latest N recent-place rows, newest first. Returns []
    /// before the model context is attached (early bootstrap path).
    /// Use this from views that need a live list — they should NOT
    /// use `@Query` directly, because we want explicit sort order +
    /// prune behaviour driven through AppState.
    func fetchRecentPlaces(limit: Int = 30) -> [RecentPlace] {
        guard let ctx = modelContext else { return [] }
        var descriptor = FetchDescriptor<RecentPlace>(
            sortBy: [SortDescriptor(\RecentPlace.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? ctx.fetch(descriptor)) ?? []
    }

    /// Insert a new entry into the recent-places log. De-dupes against
    /// the most recent entry: rapid double-teleport to the same coord
    /// (e.g. search → teleport then map-click teleport) doesn't create
    /// two adjacent rows. Prunes older rows past the cap.
    ///
    /// Called from teleport / navigate / search action paths. Cheap —
    /// one insert + at most one delete every 50 calls.
    func recordRecentPlace(label: String, lat: Double, lng: Double, kind: RecentPlace.Kind) {
        guard let ctx = modelContext else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = trimmed.isEmpty
            ? String(format: "%.5f, %.5f", lat, lng)
            : trimmed

        // De-dupe with the most-recent row when label + coord match
        // (rounded to ~11m so floating-point noise from the daemon's
        // re-projected coord doesn't make duplicates). Kind also
        // has to match — teleport then navigate to the same place is
        // two intentional actions and shouldn't collapse.
        var descriptor = FetchDescriptor<RecentPlace>(
            sortBy: [SortDescriptor(\RecentPlace.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let last = (try? ctx.fetch(descriptor))?.first,
           last.kindRaw == kind.rawValue,
           last.label == displayLabel,
           abs(last.lat - lat) < 1e-4,
           abs(last.lng - lng) < 1e-4 {
            // Bump the timestamp so the row floats back to the top
            // instead of getting buried by a no-op duplicate.
            last.createdAt = .now
            try? ctx.save()
            return
        }

        let entry = RecentPlace(label: displayLabel, lat: lat, lng: lng, kind: kind)
        ctx.insert(entry)

        // Prune anything past the cap. We pull all rows (cheap at
        // 50 max), drop the head, delete the rest. FetchDescriptor
        // doesn't expose an offset for `delete` so a manual cleanup
        // is the simplest path.
        var allDesc = FetchDescriptor<RecentPlace>(
            sortBy: [SortDescriptor(\RecentPlace.createdAt, order: .reverse)]
        )
        allDesc.fetchLimit = Self.recentPlacesCap + 16
        if let all = try? ctx.fetch(allDesc), all.count > Self.recentPlacesCap {
            for old in all.dropFirst(Self.recentPlacesCap) {
                ctx.delete(old)
            }
        }
        try? ctx.save()
    }

    /// Clear the entire recent-places log. Called from the popover's
    /// "Clear history" button.
    func clearRecentPlaces() {
        guard let ctx = modelContext else { return }
        if let all = try? ctx.fetch(FetchDescriptor<RecentPlace>()) {
            for entry in all { ctx.delete(entry) }
            try? ctx.save()
        }
    }

    /// Delete one row from the popover's swipe / X button.
    func deleteRecentPlace(_ entry: RecentPlace) {
        guard let ctx = modelContext else { return }
        ctx.delete(entry)
        try? ctx.save()
    }

    // MARK: - Bookmarks JSON import (Phase 5.5)

    /// Open an NSOpenPanel for a `.json` file, parse it as a
    /// LocWarp-style bookmarks export, and bulk-insert each entry
    /// as a Bookmark record. Categories from the JSON become
    /// per-bookmark category strings — sidebar grouping happens
    /// for free via the existing `BookmarksSection` query path.
    ///
    /// Surface any error / "nothing imported" via `lastError` so the
    /// red toast in the map overlay tells the user what happened.
    @MainActor
    func importBookmarksJSON() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Import bookmarks from JSON",
            comment: "Title of the open-file dialog for bookmarks JSON import",
        )
        guard let url = await presentPanel(panel) else { return }
        do {
            let entries = try BookmarksJSONService.parse(url: url)
            guard !entries.isEmpty else {
                lastError = String(
                    localized: "JSON parsed, but no bookmarks were found.",
                    comment: "Toast when bookmark JSON import finds zero records",
                )
                return
            }
            guard let ctx = modelContext else { return }
            // Batched insert. The previous loop called `addBookmark`
            // per-entry, which fired `ctx.save()` AND bumped
            // `bookmarksRevision` for every row. Each save flushed a
            // SwiftData transaction and notified every active @Query —
            // re-fetching the entire table 3000+ times on a large
            // import froze the UI for tens of seconds. Insert in a
            // tight loop, save once, bump once.
            for e in entries {
                let trimmed = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let nameToSave = trimmed.isEmpty
                    ? String(format: "(%.5f, %.5f)", e.lat, e.lng)
                    : trimmed
                let imgTrimmed = e.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                let imgToSave = (imgTrimmed?.isEmpty ?? true) ? nil : imgTrimmed
                let bm = Bookmark(
                    name: nameToSave,
                    lat: e.lat,
                    lng: e.lng,
                    category: e.category.trimmingCharacters(in: .whitespaces),
                    iconSymbol: "mappin.circle.fill",
                    imageURL: imgToSave,
                )
                ctx.insert(bm)
            }
            try? ctx.save()
            bookmarksRevision &+= 1
            lastError = String(
                format: String(
                    localized: "Imported %lld bookmarks.",
                    comment: "Toast after a successful bookmark JSON import",
                ),
                entries.count,
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Bookmarks JSON export + bulk paste (v1.9)

    /// Open an NSSavePanel and write all bookmarks out as LocWarp-style
    /// JSON. Filename defaults to `lociighost-bookmarks-YYYY-MM-DD.json`
    /// so successive exports don't overwrite each other unless the user
    /// picks the same name.
    @MainActor
    func exportBookmarksJSON() async {
        guard let ctx = modelContext else {
            lastError = String(localized: "Database not ready yet — try again in a second.")
            return
        }
        let all: [Bookmark]
        do {
            all = try ctx.fetch(FetchDescriptor<Bookmark>(
                sortBy: [SortDescriptor(\Bookmark.name)]
            ))
        } catch {
            lastError = "Couldn't read bookmarks: \(error.localizedDescription)"
            return
        }
        guard !all.isEmpty else {
            lastError = String(
                localized: "No bookmarks to export.",
                comment: "Toast when bookmark export is invoked on an empty list",
            )
            return
        }

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let defaultName = "lociighost-bookmarks-\(date.string(from: .now)).json"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.nameFieldStringValue = defaultName
        panel.title = String(
            localized: "Export bookmarks to JSON",
            comment: "Title of the save-file dialog for bookmarks JSON export",
        )
        guard let url = await presentPanel(panel) else { return }

        do {
            let data = try BookmarksJSONService.encodeExport(bookmarks: all)
            try data.write(to: url, options: .atomic)
            lastError = String(
                format: String(
                    localized: "Exported %lld bookmarks.",
                    comment: "Toast after a successful bookmark JSON export",
                ),
                all.count,
            )
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Parse a multi-line paste blob and insert one bookmark per line.
    /// Returns the count actually inserted. Errors are surfaced via
    /// the returned count being zero + lastError; the caller should
    /// dismiss its paste sheet either way.
    /// Parse one coord per line (`lat, lng` — comma / tab / semicolon
    /// separators) and seed the multi-stop list with them so the user
    /// can build a long route by paste instead of clicking the map
    /// dozens of times. Reuses `BookmarksJSONService.parseBulkPaste`
    /// for the actual line parser since the format overlaps; we just
    /// discard the bookmark-only name / category fields.
    ///
    /// **Side-effect: teleports the iPhone to the first parsed coord
    /// BEFORE seeding the stops.** Without that, path-planning would
    /// route from wherever the iPhone currently is (often a different
    /// country entirely when the user is planning a trip abroad), and
    /// OSRM / MapKit either fail to plan an inter-continental polyline
    /// or render a useless straight line across the ocean. Teleporting
    /// to the first stop first makes path-planning a local problem.
    /// `teleport()` clears `pendingStops` as part of its single-action
    /// semantics, so we refill from `coords` after the teleport
    /// returns. The full parsed list (including the first coord) is
    /// staged so the user sees what they pasted; the first leg of
    /// the eventual Navigate is a zero-distance no-op.
    @MainActor
    @discardableResult
    func bulkAppendStops(from rawText: String) async -> Int {
        let entries = BookmarksJSONService.parseBulkPaste(rawText)
        guard !entries.isEmpty else {
            lastError = String(
                localized: "No valid coordinates found in the pasted text.",
                comment: "Toast when multi-stop bulk paste finds zero usable coords",
            )
            return 0
        }
        let coords = entries.map { Coordinate(lat: $0.lat, lng: $0.lng) }

        if let first = coords.first,
           let udid = selectedUDID,
           devices.first(where: { $0.udid == udid })?.connected == true {
            await teleport(udid: udid, lat: first.lat, lng: first.lng)
        }

        // Replace, not append: teleport just wiped pendingStops, and
        // the user's intent on a bulk paste is "this is my new route",
        // not "tack these onto whatever was staged before".
        pendingStops = coords

        lastError = String(
            format: String(
                localized: "Added %lld stops from paste.",
                comment: "Toast after a successful multi-stop bulk-paste insert",
            ),
            coords.count,
        )
        return coords.count
    }

    @MainActor
    @discardableResult
    func bulkAddBookmarks(from rawText: String, defaultCategory: String = "") -> Int {
        let entries = BookmarksJSONService.parseBulkPaste(rawText)
        guard !entries.isEmpty else {
            lastError = String(
                localized: "No valid bookmark lines found in the pasted text.",
                comment: "Toast when bookmark bulk paste finds zero usable lines",
            )
            return 0
        }
        guard let ctx = modelContext else { return 0 }
        // Same batching contract as importBookmarksJSON — single save +
        // single revision bump so a 3000-line paste doesn't trigger
        // 3000 @Query re-fetches.
        for e in entries {
            let category = e.category.isEmpty
                ? defaultCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                : e.category
            let trimmed = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameToSave = trimmed.isEmpty
                ? String(format: "(%.5f, %.5f)", e.lat, e.lng)
                : trimmed
            let bm = Bookmark(
                name: nameToSave,
                lat: e.lat,
                lng: e.lng,
                category: category.trimmingCharacters(in: .whitespaces),
            )
            ctx.insert(bm)
        }
        try? ctx.save()
        bookmarksRevision &+= 1
        lastError = String(
            format: String(
                localized: "Added %lld bookmarks from paste.",
                comment: "Toast after a successful bookmark bulk-paste insert",
            ),
            entries.count,
        )
        return entries.count
    }

    // MARK: - Bookmarks GPX import / export (v1.17)

    /// Write every bookmark out as GPX waypoints.
    ///
    /// GPX rather than another JSON format because the point of this
    /// one is leaving LociiGhost: a `.gpx` of `<wpt>`s opens in Garmin
    /// Connect, Gaia, Organic Maps, Google Earth and Apple's own
    /// Quick Look. The JSON export stays — it is the LocWarp
    /// interchange format and carries fields GPX has no home for.
    @MainActor
    func exportBookmarksGPX() async {
        guard let ctx = modelContext else {
            lastError = String(localized: "Database not ready yet — try again in a second.")
            return
        }
        let all: [Bookmark]
        do {
            all = try ctx.fetch(FetchDescriptor<Bookmark>(
                sortBy: [SortDescriptor(\Bookmark.name)]
            ))
        } catch {
            lastError = "Couldn't read bookmarks: \(error.localizedDescription)"
            return
        }
        guard !all.isEmpty else {
            lastError = String(
                localized: "No bookmarks to export.",
                comment: "Toast when bookmark export is invoked on an empty list",
            )
            return
        }

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.nameFieldStringValue = "lociighost-bookmarks-\(date.string(from: .now)).gpx"
        panel.title = String(
            localized: "Export bookmarks to GPX",
            comment: "Title of the save-file dialog for bookmarks GPX export",
        )
        guard let url = await presentPanel(panel) else { return }

        let xml = BookmarkGPX.encode(all.map { waypoint(for: $0) })
        guard let data = xml.data(using: .utf8) else {
            // Same trap as GPXService's L18 fix: a nil encode must not
            // report a successful export of a file that isn't there.
            lastError = String(localized: "Export failed: could not encode the file as UTF-8.")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            lastError = String(
                format: String(
                    localized: "Exported %lld bookmarks.",
                    comment: "Toast after a successful bookmark GPX export",
                ),
                all.count,
            )
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Read a `.gpx` file and insert one bookmark per `<wpt>`.
    ///
    /// Any GPX file works, not only ours — a foreign waypoint lands
    /// uncategorised with the default pin. Category colours ride along
    /// in an extension element and are applied as overrides here,
    /// which is the only part of the import that touches state outside
    /// the bookmarks table.
    @MainActor
    func importBookmarksGPX() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Import bookmarks from GPX",
            comment: "Title of the open-file dialog for bookmarks GPX import",
        )
        guard let url = await presentPanel(panel) else { return }
        guard let ctx = modelContext else { return }

        let waypoints: [BookmarkWaypoint]
        do {
            waypoints = try BookmarkGPX.decode(try Data(contentsOf: url))
        } catch let error as BookmarkGPXError {
            lastError = Self.message(for: error)
            return
        } catch {
            lastError = error.localizedDescription
            return
        }

        // Batched insert, one save, one revision bump — a 3 000-pin
        // file would otherwise re-fetch every @Query 3 000 times.
        for w in waypoints {
            let trimmed = w.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameToSave = trimmed.isEmpty
                ? String(format: "(%.5f, %.5f)", w.lat, w.lng)
                : trimmed
            let bm = Bookmark(
                name: nameToSave,
                lat: w.lat,
                lng: w.lng,
                category: w.category.trimmingCharacters(in: .whitespaces),
                iconSymbol: Self.usableSymbol(w.symbol),
                imageURL: w.imageURL,
            )
            ctx.insert(bm)
        }
        try? ctx.save()

        // Colours after the insert: applying them writes preferences,
        // and doing that per-waypoint mid-import would persist the
        // JSON blob once per pin.
        for w in waypoints {
            guard let hex = w.colorHex else { continue }
            setCategoryColor(hex, for: w.category)
        }

        bookmarksRevision &+= 1
        lastError = String(
            format: String(
                localized: "Imported %lld bookmarks.",
                comment: "Toast after a successful bookmark GPX import",
            ),
            waypoints.count,
        )
    }

    /// One bookmark as a waypoint.
    ///
    /// The colour is emitted only when the user actually picked one:
    /// `CategoryPalette` derives the rest from the category name with
    /// a hash we own, so they are already identical on the machine
    /// this file lands on. Writing them would convert every derived
    /// colour into an explicit override on import.
    private func waypoint(for bm: Bookmark) -> BookmarkWaypoint {
        BookmarkWaypoint(
            name: bm.name,
            lat: bm.lat,
            lng: bm.lng,
            category: bm.category,
            symbol: bm.iconSymbol,
            colorHex: categoryColorOverrides[CategoryPalette.key(for: bm.category)],
            imageURL: bm.imageURL,
        )
    }

    /// Keep an imported `<sym>` only if it will actually draw.
    ///
    /// GPX's `sym` is a free-form string and other apps put their own
    /// vocabulary in it ("Flag, Blue"). Storing that verbatim gives a
    /// bookmark whose icon renders as nothing at all, so anything that
    /// isn't one of our flowers or a real SF Symbol falls back to the
    /// default pin.
    private static func usableSymbol(_ raw: String?) -> String {
        let fallback = "mappin.circle.fill"
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return fallback }
        // A `flower.` value is kept verbatim even when this build
        // doesn't know the id: the renderer already falls back to a
        // daisy for those, and rewriting it here would permanently
        // flatten a flower added by a newer version the first time an
        // older one imported the file.
        if raw.hasPrefix(FlowerPin.symbolPrefix) { return raw }
        return NSImage(systemSymbolName: raw, accessibilityDescription: nil) == nil
            ? fallback
            : raw
    }

    private static func message(for error: BookmarkGPXError) -> String {
        switch error {
        case .unparseable(let why):
            return String(
                format: String(
                    localized: "GPX file is malformed: %@",
                    comment: "Error when bookmark GPX import fails to parse",
                ),
                why,
            )
        case .empty:
            return String(
                localized: "GPX parsed, but it has no waypoints. Tracks import as routes, not bookmarks — use File ▸ Import GPX for those.",
                comment: "Error when an imported GPX has tracks but no waypoints",
            )
        }
    }
}
