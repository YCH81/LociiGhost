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

// Route library JSON import and export.

extension AppState {
    // MARK: - Routes JSON import / export + force-restart (v1.9.1)

    /// Open an NSOpenPanel for a `.json` routes export, parse it, and
    /// bulk-insert each entry as a Route record. Mirrors
    /// `importBookmarksJSON()` for the routes table. Surfaces errors
    /// / "nothing imported" via `lastError`.
    /// Open NSOpenPanel for a JSON routes file, parse + bulk-insert. Returns
    /// a user-facing result string (success or failure) so callers presented
    /// in a sheet (Settings → Routes) can surface it inline — the
    /// MainView-mounted `lastError` toast is hidden behind the sheet.
    /// Returns `nil` only when the user cancels the open dialog.
    @MainActor
    func importRoutesJSON() async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Import routes from JSON",
            comment: "Title of the open-file dialog for routes JSON import",
        )
        guard let url = await presentPanel(panel) else { return nil }
        do {
            let entries = try RoutesJSONService.parse(url: url)
            guard !entries.isEmpty else {
                let msg = String(
                    localized: "JSON parsed, but no routes were found.",
                    comment: "Toast when route JSON import finds zero records",
                )
                lastError = msg
                return msg
            }
            for e in entries {
                saveImportedRoute(
                    name: e.name,
                    coordinates: e.points,
                    category: e.category,
                    iconSymbol: e.iconSymbol
                        ?? "point.bottomleft.forward.to.point.topright.scurvepath.fill",
                )
            }
            let msg = String(
                format: String(
                    localized: "Imported %lld routes.",
                    comment: "Toast after a successful route JSON import",
                ),
                entries.count,
            )
            lastError = msg
            return msg
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            return msg
        }
    }

    /// NSSavePanel → JSON for every saved Route. Default filename
    /// includes today's date so successive exports don't clobber.
    /// Returns a user-facing result string for sheet-local rendering
    /// (Settings → Routes); `nil` only when the user cancels the save
    /// dialog.
    @MainActor
    func exportRoutesJSON() async -> String? {
        guard let ctx = modelContext else {
            let msg = String(localized: "Database not ready yet — try again in a second.")
            lastError = msg
            return msg
        }
        let all: [Route]
        do {
            all = try ctx.fetch(FetchDescriptor<Route>(
                sortBy: [SortDescriptor(\Route.name)]
            ))
        } catch {
            let msg = "Couldn't read routes: \(error.localizedDescription)"
            lastError = msg
            return msg
        }
        guard !all.isEmpty else {
            let msg = String(
                localized: "No routes to export.",
                comment: "Toast when route export is invoked on an empty list",
            )
            lastError = msg
            return msg
        }

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let defaultName = "lociighost-routes-\(date.string(from: .now)).json"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "json")!]
        panel.nameFieldStringValue = defaultName
        panel.title = String(
            localized: "Export routes to JSON",
            comment: "Title of the save-file dialog for routes JSON export",
        )
        guard let url = await presentPanel(panel) else { return nil }

        do {
            let data = try RoutesJSONService.encodeExport(routes: all)
            try data.write(to: url, options: .atomic)
            let msg = String(
                format: String(
                    localized: "Exported %lld routes.",
                    comment: "Toast after a successful route JSON export",
                ),
                all.count,
            )
            lastError = msg
            return msg
        } catch {
            let msg = "Export failed: \(error.localizedDescription)"
            lastError = msg
            return msg
        }
    }
}
