import SwiftUI
import AppKit

/// Slim chrome strip pinned to the very top of the window, above
/// `TopStatusBar`. Renders three things:
///
///   * App identity + version on the left
///   * Quick EN ↔ 中文 toggle in the middle
///   * Phone Control button on the right
///
/// We deliberately avoid the macOS toolbar API here because we want
/// the language toggle to be one click (toolbars eat clicks for menu
/// expansion / customise sheet) and because the standard window
/// chrome already gets crowded by Settings's window controls.
struct AppHeaderBar: View {
    @Environment(AppState.self) private var state
    /// SwiftUI's macOS 14+ programmatic Settings opener. Triggered
    /// from the gear button we sit left of the language toggle.
    @Environment(\.openSettings) private var openSettings
    /// Bound from `LociiGhostApp` where the @AppStorage lives — passing
    /// it down rather than re-reading the storage in this view keeps
    /// the source-of-truth single-rooted and lets the toggle button
    /// flip between EN and 中文 with no extra plumbing.
    @Binding var appLanguage: AppLanguage

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                // v1.9.4: actual app icon (the paper-plane AppIcon.icns
                // from Contents/Resources) instead of an SF Symbol —
                // `NSApp.applicationIconImage` resolves at runtime to
                // whatever the bundle's icon currently is, so this
                // strip's wordmark always stays in sync with the Dock
                // badge. No PNG re-bundling needed when the master
                // design changes; rebuilding the .icns is enough.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                Text("LociiGhost")
                    .font(.callout.weight(.semibold))
                Text("v\(versionString)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let latest = state.latestVersion {
                    updateBadge(latestVersion: latest)
                }
            }
            Spacer(minLength: 12)
            autoRecenterToggle
            settingsButton
            languageToggle
            Divider().frame(height: 14)
            phoneControlButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar.opacity(0.9))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Small green capsule next to the version label. Visible only
    /// when `AppState.checkForUpdates()` found a newer release on
    /// the remote manifest; click opens the release page.
    @ViewBuilder
    private func updateBadge(latestVersion: String) -> some View {
        Button {
            if let url = state.latestVersionURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
                Text("New v\(latestVersion)",
                     comment: "AppHeaderBar — update-available badge text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.15), in: .capsule)
            .overlay(
                Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5),
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 12)
        .help(Text("Update available — click to view release",
                   comment: "Tooltip on the update-available badge"))
    }

    /// v1.11.0 hotfix — toggle for the map auto-recenter behaviour.
    /// On (default): the map follows the simulated pin every 1 Hz
    /// tick during joystick / random walk / navigation. Off: the map
    /// stays where the user left it; one-shot teleports (route-start
    /// fly, Recent Places, preset Teleport) still pan since those use
    /// `pendingMapFly` directly. Sits left of the Settings pill in
    /// the header bar so the user can flip it without diving into
    /// Settings → … just because they want to read a corner of the
    /// map mid-trip.
    private var autoRecenterToggle: some View {
        @Bindable var state = state
        return Button {
            state.mapAutoRecenter.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.mapAutoRecenter
                      ? "location.viewfinder"
                      : "location.slash")
                    .font(.caption)
                    .foregroundStyle(state.mapAutoRecenter ? Color.lociSage : Color.secondary)
                Text("Auto-center",
                     comment: "Header bar — toggle for map auto-recenter during simulated movement")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.mapAutoRecenter ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                state.mapAutoRecenter
                    ? AnyShapeStyle(Color.lociSage.opacity(0.15))
                    : AnyShapeStyle(Color.secondary.opacity(0.08)),
                in: .capsule
            )
            .overlay(
                Capsule().strokeBorder(
                    state.mapAutoRecenter
                        ? Color.lociSage.opacity(0.45)
                        : Color.secondary.opacity(0.25),
                    lineWidth: 0.5
                ),
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 12)
        .help(LocalizedStringKey("Toggle map auto-recenter: when on, the map follows the simulated location during movement. When off, the map stays put — teleports and route starts still pan once, then you scroll the map manually."))
    }

    /// v1.9 Settings shortcut — sits left of the language toggle so
    /// the user can reach Bookmarks / Logs / Google API key / Alert
    /// sound without remembering Cmd-,. SwiftUI's `openSettings`
    /// drives the same Settings scene the menu shortcut does, so we
    /// stay consistent with the macOS-native path.
    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gearshape.fill")
                    .font(.caption)
                Text("Settings",
                     comment: "Header bar — opens the Settings sheet")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: .capsule)
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5),
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: [.command])
        .hoverHighlight(cornerRadius: 12)
        .help(LocalizedStringKey("Open Settings — bookmarks tools, logs, Google API key, alert sound (Cmd-,)"))
    }

    /// Three-position cycle: System → English → 中文 → System. We
    /// still expose the full picker in Settings (Cmd-,); this is just
    /// the impatient-user shortcut. Each pill gets a hover background
    /// so the user knows it's a button, not a label.
    private var languageToggle: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(AppLanguage.allCases) { lang in
                Button {
                    appLanguage = lang
                } label: {
                    Text(shortLabel(for: lang))
                        .font(.caption.weight(appLanguage == lang ? .semibold : .regular))
                        .foregroundStyle(appLanguage == lang
                                         ? Color.lociSage
                                         : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            appLanguage == lang
                                ? AnyShapeStyle(Color.lociSage.opacity(0.18))
                                : AnyShapeStyle(Color.clear),
                            in: .capsule,
                        )
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 12, changesCursor: false)
                .help(lang.displayName)
            }
        }
    }

    private func shortLabel(for lang: AppLanguage) -> String {
        switch lang {
        case .system: return "Auto"
        case .en:     return "EN"
        case .zhHant: return "中"
        }
    }

    /// Phone Control — chunkier than a default toolbar button so the
    /// user can find it without hunting. Bordered prominent style +
    /// our hover highlight gives a clear "this is the primary action
    /// in this strip" signal.
    private var phoneControlButton: some View {
        Button {
            state.openPhoneControlSheet()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.body)
                Text("Phone Control",
                     comment: "Header bar — opens the LAN URL + PIN modal")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        // No explicit .tint() — inherits the WindowGroup's
        // `appearanceMode.tint` from the environment so the Phone
        // Control button flips with the rest of the UI when the
        // user switches between brand and system appearance.
        .controlSize(.regular)
        .hoverHighlight(cornerRadius: 6)
        .help(LocalizedStringKey("Drive LociiGhost from your phone over WiFi."))
    }

    /// The daemon's reported version — falls back to the version the
    /// app was built against if the daemon hasn't connected yet so the
    /// chip never shows "v" alone during the first-second handshake.
    private var versionString: String {
        if !state.daemonVersion.isEmpty { return state.daemonVersion }
        return AppState.expectedDaemonVersion
    }
}
