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

// Whole-library backup: export, import, and the merge strategies.

extension AppState {
    // MARK: - Full backup (v1.11.2)

    /// Dump every user-generated entity (bookmarks + routes + stop
    /// presets) to a single versioned JSON file via NSSavePanel.
    /// Designed for "I'm about to wipe / migrate / reinstall" — one
    /// file, one round-trip back through `importAllBackup()`.
    @MainActor
    func exportAllBackup() async {
        guard let ctx = modelContext else {
            lastError = String(localized: "Database not ready yet — try again in a second.")
            return
        }
        let bookmarks = (try? ctx.fetch(FetchDescriptor<Bookmark>(
            sortBy: [SortDescriptor(\Bookmark.createdAt)],
        ))) ?? []
        let routes = (try? ctx.fetch(FetchDescriptor<Route>(
            sortBy: [SortDescriptor(\Route.createdAt)],
        ))) ?? []
        let presets = (try? ctx.fetch(FetchDescriptor<StopPreset>(
            sortBy: [SortDescriptor(\StopPreset.createdAt)],
        ))) ?? []

        guard !bookmarks.isEmpty || !routes.isEmpty || !presets.isEmpty else {
            lastError = String(
                localized: "Nothing to back up — no bookmarks, routes, or stop presets yet.",
                comment: "Toast when full-backup export finds an empty database",
            )
            return
        }

        let bundle = FullBackupBundle(
            version: 1,
            exportedAt: .now,
            bookmarks: bookmarks.map {
                FullBackupBundle.BookmarkEntry(
                    name: $0.name,
                    lat: $0.lat,
                    lng: $0.lng,
                    category: $0.category,
                    iconSymbol: $0.iconSymbol,
                    createdAt: $0.createdAt,
                    imageURL: $0.imageURL,
                )
            },
            routes: routes.map {
                FullBackupBundle.RouteEntry(
                    name: $0.name,
                    category: $0.category,
                    iconSymbol: $0.iconSymbol,
                    points: $0.points.map { [$0.lat, $0.lng] },
                    createdAt: $0.createdAt,
                )
            },
            stopPresets: presets.map {
                FullBackupBundle.StopPresetEntry(
                    name: $0.name,
                    points: $0.coordinates.map { [$0.lat, $0.lng] },
                    createdAt: $0.createdAt,
                )
            },
        )

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let defaultName = "lociighost-backup-\(date.string(from: .now)).json"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.nameFieldStringValue = defaultName
        panel.title = String(
            localized: "Export all data (full backup)",
            comment: "Title of the save-file dialog for full backup export",
        )
        guard let url = await presentPanel(panel) else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(bundle)
            try data.write(to: url, options: .atomic)
            lastError = String(
                format: String(
                    localized: "Backed up %lld bookmarks · %lld routes · %lld presets.",
                    comment: "Toast after a successful full-backup export",
                ),
                bookmarks.count, routes.count, presets.count,
            )
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// Open a previously-exported backup JSON, prompt the user to pick
    /// a merge / overwrite strategy via NSAlert, then apply. Refuses to
    /// proceed if the version is newer than this build understands —
    /// downgrade-on-restore is a footgun we don't ship.
    @MainActor
    func importAllBackup() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Restore from backup JSON",
            comment: "Title of the open-file dialog for full backup import",
        )
        guard let url = await presentPanel(panel) else { return }

        let bundle: FullBackupBundle
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            bundle = try decoder.decode(FullBackupBundle.self, from: data)
        } catch {
            lastError = "Restore failed: couldn't parse backup file — \(error.localizedDescription)"
            return
        }

        guard bundle.version <= 1 else {
            lastError = String(
                localized: "This backup is from a newer LociiGhost version. Please update before restoring.",
                comment: "Toast when full-backup import sees a higher schema version than this build supports",
            )
            return
        }

        // Strategy dialog — three buttons, NSAlert returns first /
        // second / third button for Merge / Overwrite / Cancel.
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Restore from backup?",
            comment: "Full-backup import — strategy dialog title",
        )
        alert.informativeText = String(
            format: String(
                localized: "This backup contains %lld bookmarks · %lld routes · %lld presets.\n\nMerge keeps your existing data and adds new entries (skipping name+coords duplicates).\nOverwrite wipes everything currently in LociiGhost and replaces it with the backup.",
                comment: "Full-backup import — strategy dialog body explaining merge vs overwrite",
            ),
            bundle.bookmarks.count, bundle.routes.count, bundle.stopPresets.count,
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "Merge",
            comment: "Full-backup import — merge button",
        ))
        alert.addButton(withTitle: String(
            localized: "Overwrite",
            comment: "Full-backup import — overwrite button (destructive)",
        ))
        alert.addButton(withTitle: String(
            localized: "Cancel",
            comment: "Full-backup import — cancel button",
        ))

        let response = alert.runModal()
        let strategy: BackupImportStrategy
        switch response {
        case .alertFirstButtonReturn:  strategy = .merge
        case .alertSecondButtonReturn: strategy = .overwrite
        default: return  // user cancelled
        }

        applyBackup(bundle, strategy: strategy)
    }

    /// Insert (and optionally wipe-first) bundle records into the
    /// SwiftData store. Dedupe key is `(name, coords)` for all three
    /// entity types — same name+different coords becomes a separate
    /// entry, same coords+different name becomes a separate entry.
    @MainActor
    private func applyBackup(_ bundle: FullBackupBundle, strategy: BackupImportStrategy) {
        guard let ctx = modelContext else {
            lastError = String(localized: "Database not ready yet — try again in a second.")
            return
        }

        if strategy == .overwrite {
            if let bms = try? ctx.fetch(FetchDescriptor<Bookmark>()) {
                for b in bms { ctx.delete(b) }
            }
            if let rs = try? ctx.fetch(FetchDescriptor<Route>()) {
                for r in rs { ctx.delete(r) }
            }
            if let ps = try? ctx.fetch(FetchDescriptor<StopPreset>()) {
                for p in ps { ctx.delete(p) }
            }
        }

        // Build dedupe sets up front so the per-entry merge check is
        // O(1); rebuilding the set per-entry would be O(N²) for a
        // big backup against a big database.
        var bookmarkKeys: Set<String> = []
        var routeKeys: Set<String> = []
        var presetKeys: Set<String> = []
        if strategy == .merge {
            if let bms = try? ctx.fetch(FetchDescriptor<Bookmark>()) {
                for b in bms {
                    bookmarkKeys.insert(Self.bookmarkKey(name: b.name, lat: b.lat, lng: b.lng))
                }
            }
            if let rs = try? ctx.fetch(FetchDescriptor<Route>()) {
                for r in rs {
                    routeKeys.insert(Self.coordsKey(name: r.name, points: r.points))
                }
            }
            if let ps = try? ctx.fetch(FetchDescriptor<StopPreset>()) {
                for p in ps {
                    presetKeys.insert(Self.coordsKey(name: p.name, points: p.coordinates))
                }
            }
        }

        var addedBookmarks = 0, addedRoutes = 0, addedPresets = 0

        for entry in bundle.bookmarks {
            if strategy == .merge,
               bookmarkKeys.contains(Self.bookmarkKey(name: entry.name, lat: entry.lat, lng: entry.lng)) {
                continue
            }
            let bm = Bookmark(
                name: entry.name,
                lat: entry.lat,
                lng: entry.lng,
                category: entry.category,
                iconSymbol: entry.iconSymbol,
                imageURL: entry.imageURL,
                createdAt: entry.createdAt ?? .now,
            )
            ctx.insert(bm)
            addedBookmarks += 1
        }

        for entry in bundle.routes {
            let coords: [Coordinate] = entry.points.compactMap { pt in
                guard pt.count == 2 else { return nil }
                return Coordinate(lat: pt[0], lng: pt[1])
            }
            if strategy == .merge,
               routeKeys.contains(Self.coordsKey(name: entry.name, points: coords)) {
                continue
            }
            let r = Route(
                name: entry.name,
                points: coords,
                category: entry.category,
                iconSymbol: entry.iconSymbol,
                createdAt: entry.createdAt ?? .now,
            )
            ctx.insert(r)
            addedRoutes += 1
        }

        for entry in bundle.stopPresets {
            let coords: [Coordinate] = entry.points.compactMap { pt in
                guard pt.count == 2 else { return nil }
                return Coordinate(lat: pt[0], lng: pt[1])
            }
            if strategy == .merge,
               presetKeys.contains(Self.coordsKey(name: entry.name, points: coords)) {
                continue
            }
            let p = StopPreset(
                name: entry.name,
                coordinates: coords,
                createdAt: entry.createdAt ?? .now,
            )
            ctx.insert(p)
            addedPresets += 1
        }

        do {
            try ctx.save()
            if addedBookmarks > 0 { bookmarksRevision &+= 1 }
            lastError = String(
                format: String(
                    localized: "Restored: %lld bookmarks · %lld routes · %lld presets added.",
                    comment: "Toast after a successful full-backup restore",
                ),
                addedBookmarks, addedRoutes, addedPresets,
            )
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Dedupe key for Bookmark: name + 6-decimal coords. Six decimals
    /// is the same precision the UI prints, so two records that look
    /// identical to the user collapse to the same key.
    private static func bookmarkKey(name: String, lat: Double, lng: Double) -> String {
        "\(name)|\(String(format: "%.6f,%.6f", lat, lng))"
    }

    /// Dedupe key for Route / StopPreset: name + concatenated coords.
    /// Two routes with the same name but different points become
    /// distinct entries (the user clearly authored them separately).
    private static func coordsKey(name: String, points: [Coordinate]) -> String {
        let hash = points.map { String(format: "%.6f,%.6f", $0.lat, $0.lng) }
            .joined(separator: ";")
        return "\(name)|\(hash)"
    }
}
