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

// GPX import and export.

extension AppState {
    // MARK: - GPX import / export (Phase 5.4)

    /// Open an NSOpenPanel for a `.gpx` file, parse it, and surface
    /// the result through `pendingRouteImport` so the RouteEditSheet
    /// can ask the user for a name + category before persisting.
    ///
    /// We deliberately do NOT downsample or otherwise mutate the
    /// imported coordinates — a 274-point Tokyo walk should land in
    /// the saved route exactly as recorded. Click-to-execute on the
    /// resulting Route uses straight-line mode so OSRM's URL-length
    /// limit doesn't bite (see `runRoute`).
    @MainActor
    func importGPX() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gpx")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Import GPX",
                             comment: "Title of the open-file dialog for GPX import")
        guard let url = await presentPanel(panel) else { return }
        do {
            let coords = try GPXService.loadCoordinates(from: url)
            // Prefill the name field with the filename stem. Most GPX
            // exports name the file after the trip ("morning-walk.gpx"
            // → "morning-walk"), and reusing that lets the user just
            // hit Save without retyping.
            let suggested = url.deletingPathExtension().lastPathComponent
            pendingRouteImport = PendingRouteImport(
                suggestedName: suggested,
                coordinates: coords,
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Save current `pendingStops` (the user's staged route) to a
    /// `.gpx` file via NSSavePanel. Refuses to save when the list
    /// is empty — File > Export menu item is disabled for that case
    /// already, this is a belt-and-suspenders guard.
    @MainActor
    func exportGPX() async {
        guard !pendingStops.isEmpty else {
            lastError = String(localized: "No stops staged yet.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gpx")!]
        panel.nameFieldStringValue = "lociighost-route.gpx"
        panel.title = String(localized: "Export current route as GPX…",
                             comment: "Title of the save-file dialog for GPX export")
        guard let url = await presentPanel(panel) else { return }
        do {
            try GPXService.write(coordinates: pendingStops, to: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
