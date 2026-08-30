import AppKit
import CoreLocation
import Foundation
import LociiGhostCore

/// Policy shared by the two map implementations.
///
/// v1.15.2 audit (P12): `MapContainerView` (1627 lines) and
/// `NativeMapView` (801) each grew their own copy of the same
/// decisions — which context-menu items exist, when each is enabled,
/// the AppleLanguages localisation workaround, the S2 scanline cap,
/// and the camera-save debounce. That duplication is not theoretical:
/// P3 in the same audit was a bug caused by exactly it. The
/// programmatic-fly guard was added to `MapContainerView` with a
/// comment explaining that without it the SwiftData WAL floods and
/// the app lags within minutes — and `NativeMapView`, the path most
/// users are actually on, never got it.
///
/// The split here is deliberate: the *policy* lives in this file
/// because that is what drifted, while the AppKit plumbing (targets,
/// selectors, `representedObject` vs. a stored coordinate) stays with
/// each view, because the two use genuinely different mechanisms and
/// forcing them together would be worse than the duplication.

// MARK: - Context menu

/// What a map's right-click menu can do. The cases are the shared
/// vocabulary; each view maps them onto its own target/action wiring.
enum MapMenuAction: Hashable {
    case teleport
    case addStop
    case copyCoordinate
    case bookmark
}

/// One menu row, fully decided except for how it gets invoked.
struct MapMenuItemSpec {
    let action: MapMenuAction
    /// Already localised — see `MapContextMenuPolicy.localized`.
    let title: String
    let symbolName: String
    let isEnabled: Bool
    /// Tooltip shown when disabled. Says what to do about it rather
    /// than restating that the item is unavailable.
    let disabledHint: String?
    /// Whether a separator belongs above this row.
    let separatorBefore: Bool
}

enum MapContextMenuPolicy {

    /// Disabled first row: reads as information, not an action.
    static func headerTitle(for coord: CLLocationCoordinate2D) -> String {
        String(format: "📍  %.5f, %.5f", coord.latitude, coord.longitude)
    }

    /// Localised lookup for `NSMenu`, honouring the app's own language
    /// picker.
    ///
    /// Needed because NSMenu is AppKit — SwiftUI's `\.locale`
    /// environment doesn't reach it — and because
    /// `String(localized:)` resolves through
    /// `Bundle.main.preferredLocalizations`, which this app forces to
    /// `[zh-Hant, en]` at launch so MapKit renders Chinese labels.
    /// Without this every menu item would silently lock to zh-Hant.
    /// `appLanguage` is read straight from UserDefaults because that
    /// is where `@AppStorage` keeps it.
    static func localized(_ key: String) -> String {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let target: String
        switch lang {
        case "en":      target = "en"
        case "zh-Hant": target = "zh-Hant"
        default:        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        if let path = Bundle.main.path(forResource: target, ofType: "lproj"),
           let lprojBundle = Bundle(path: path) {
            return lprojBundle.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// The menu's rows, in order, with enablement already decided.
    @MainActor
    static func items(for coord: CLLocationCoordinate2D,
                      state: AppState) -> [MapMenuItemSpec] {
        let isConnected = state.devices
            .first(where: { $0.udid == state.selectedUDID })?
            .connected ?? false

        // "Add as stop" only makes sense once Multi-stop is open —
        // left-clicking the map follows the same rule. Right-clicking
        // while a route / random walk / joystick is running used to
        // append to pendingStops anyway, which was confusing because
        // the new pin never appeared in any visible staging list.
        let canAddStop = state.activeMovementMode == .multiStop

        return [
            MapMenuItemSpec(
                action: .teleport,
                title: localized("Teleport here"),
                symbolName: "wand.and.stars",
                isEnabled: isConnected,
                disabledHint: isConnected ? nil : localized("Connect a device first."),
                separatorBefore: false,
            ),
            MapMenuItemSpec(
                action: .addStop,
                title: localized("Add as stop"),
                symbolName: "mappin.and.ellipse",
                isEnabled: canAddStop,
                disabledHint: canAddStop ? nil : localized("Switch to Multi-stop mode first"),
                separatorBefore: false,
            ),
            // Copy sits after the two actions and before the bookmark
            // section: "do something with this point" then "remember
            // this point", so the user doesn't have to scan the whole
            // menu to find either.
            MapMenuItemSpec(
                action: .copyCoordinate,
                title: localized("Copy coordinates"),
                symbolName: "doc.on.doc",
                isEnabled: true,
                disabledHint: nil,
                separatorBefore: false,
            ),
            MapMenuItemSpec(
                action: .bookmark,
                title: localized("Save as bookmark…"),
                symbolName: "bookmark",
                isEnabled: true,
                disabledHint: nil,
                separatorBefore: true,
            ),
        ]
    }

    /// Build the shared skeleton. `wire` is handed each row and the
    /// `NSMenuItem` built for it, and attaches whatever target/action
    /// that view uses; it is only called for enabled rows.
    @MainActor
    static func buildMenu(
        for coord: CLLocationCoordinate2D,
        state: AppState,
        wire: (MapMenuItemSpec, NSMenuItem) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        // Explicit enablement is the whole point of the `disabledHint`
        // tooltips, so don't let AppKit's automatic enabling override
        // it. MapContainerView set both `isEnabled = false` AND a valid
        // target/action, and with autoenablesItems left at its default
        // `true` AppKit re-enabled the row from the target — so
        // "Teleport here" was clickable with nothing connected.
        menu.autoenablesItems = false

        let header = NSMenuItem()
        header.title = headerTitle(for: coord)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for spec in items(for: coord, state: state) {
            if spec.separatorBefore { menu.addItem(.separator()) }
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: spec.symbolName,
                                 accessibilityDescription: nil)
            item.isEnabled = spec.isEnabled
            if spec.isEnabled {
                wire(spec, item)
            } else {
                item.toolTip = spec.disabledHint
            }
            menu.addItem(item)
        }
        return menu
    }
}

// MARK: - Geometry

enum MapGeometryPolicy {
    /// Upper bound on S2 scanline overlays per redraw. The grid is
    /// drawn as scanlines rather than per-cell, so this bounds the
    /// overlay count at roughly √cells.
    static let s2ScanlineCap = 2_000

    /// Above this many staged stops we stop drawing every pin.
    static let stopPinDecimationThreshold = 100
    /// …and draw roughly every N-th instead. 101 rather than 100 so a
    /// route whose length is a round multiple doesn't land every
    /// sampled pin on the same visual rhythm.
    static let stopPinDecimationStep = 101

    /// First pin, every step-th in between, and the last — with
    /// original indices preserved so labels stay truthful.
    static func decimatedStops(_ all: [Coordinate]) -> [(Int, Coordinate)] {
        let n = all.count
        if n <= stopPinDecimationThreshold {
            return all.enumerated().map { ($0.offset, $0.element) }
        }
        var out: [(Int, Coordinate)] = []
        out.reserveCapacity(n / stopPinDecimationStep + 2)
        out.append((0, all[0]))
        var i = stopPinDecimationStep
        while i < n - 1 {
            out.append((i, all[i]))
            i += stopPinDecimationStep
        }
        // Only append the last when it isn't already the most recent
        // entry — true whenever n - 1 isn't a multiple of step.
        if out.last?.0 != n - 1 {
            out.append((n - 1, all[n - 1]))
        }
        return out
    }
}

// MARK: - Camera persistence

enum CameraPersistencePolicy {
    /// How long the camera must sit still before we write it.
    ///
    /// Was 500 ms in both maps. Programmatic follow ticks arrive every
    /// 1000 ms while navigating, so a 500 ms debounce could never
    /// coalesce them: every single tick reached `modelContext.save()`.
    /// 1.5 s is longer than the tick interval, so a followed camera
    /// writes once when the user stops rather than once per second.
    /// The programmatic-fly guard in each view is the primary defence;
    /// this is the backstop that makes an escaped tick harmless.
    static let saveDebounce: Duration = .milliseconds(1500)

    /// Never persist a span tighter than this — a degenerate value
    /// restores as an unusably zoomed-in map on next launch.
    static let minSpanMeters: Double = 500
}
