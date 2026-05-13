import SwiftUI
import AppKit
import LociiGhostCore

/// Cmd-, settings sheet. v1.9 expansion: hosts the language picker
/// PLUS bookmark utilities, log-folder shortcut, Google geocoding
/// API key field, and the route-complete alert toggle. One single
/// vertical layout instead of tabs — each section is short and tabs
/// would feel oversized for the amount of content.
struct SettingsView: View {
    @Binding var appLanguage: AppLanguage
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var googleKeyDraft: String = ""
    @State private var showingBulkPasteSheet: Bool = false
    /// Sheet-local toast for routes import / export results. The
    /// global `state.lastError` toast lives in MainView and is hidden
    /// behind this Settings sheet, so without this inline echo the user
    /// gets zero feedback when they hit Import/Export JSON. Auto-clears
    /// ~5 s after each result.
    @State private var routesIOMessage: String?

    var body: some View {
        // NB: We can't shadow-bind `@Bindable var state = state` at
        // the `body` scope and have `$state.x` work inside the
        // section helpers below — those are computed properties on
        // the struct and don't see the body's local. So the Toggle
        // / Picker bindings stay in `Binding(get:set:)` form. That
        // form is safe in v1.9.3+ because the underlying
        // `alertSoundEnabled` / `routingEngine` / `googleGeocodeAPIKey`
        // are now stored @Observable properties (not computed proxies
        // to SwiftData), so observation tracking is well-behaved.
        VStack(spacing: 0) {
            // Header strip — same affordances as a macOS-native
            // sheet (drag handle / close button) plus a title.
            HStack {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.tint)
                Text("Settings",
                     comment: "Title of the Settings sheet")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(LocalizedStringKey("Close Settings"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appearanceSection
                    Divider()
                    bookmarksSection
                    Divider()
                    routesSection
                    Divider()
                    routingEngineSection
                    Divider()
                    logsSection
                    Divider()
                    geocodingSection
                    Divider()
                    alertsSection
                    Divider()
                    troubleshootingSection
                    Divider()
                    aboutSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 580, minHeight: 660)
        .sheet(isPresented: $showingBulkPasteSheet) {
            BulkPasteBookmarksSheet()
                .environment(state)
        }
        .onAppear {
            googleKeyDraft = state.googleGeocodeAPIKey ?? ""
        }
    }

    // MARK: - Appearance (language)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "globe", titleKey: "Appearance")

            HStack {
                Text("Language:",
                     comment: "Settings — language picker label")
                Picker(selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                Spacer()
            }

            // v1.9.4 appearance-mode picker. Stored as a Binding(get/set)
            // wrapper because `appState` is environment-injected and
            // `$state.appearanceMode` isn't visible from this computed-
            // property section (same constraint as the routingEngine
            // picker). Underlying property is a stored @Observable
            // value, so the binding is safe.
            HStack {
                Text("Theme:",
                     comment: "Settings — appearance theme picker label")
                let themeBinding = Binding<AppearanceMode>(
                    get: { state.appearanceMode },
                    set: { state.appearanceMode = $0 },
                )
                Picker(selection: themeBinding) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
                Spacer()
            }

            Text("Default appearance uses the sage palette from the LociiGhost icon. System appearance reverts every tinted element to macOS's accent colour. Switching is live — no restart needed.",
                 comment: "Help text under the appearance picker")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bookmarks

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "bookmark.fill", titleKey: "Bookmarks")
            Text("Move bookmarks between machines or paste many at once.",
                 comment: "Settings — Bookmarks section explanation")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    Task { @MainActor in await state.importBookmarksJSON() }
                } label: {
                    Label {
                        Text("Import from JSON…",
                             comment: "Settings — bookmarks import button")
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                Button {
                    Task { @MainActor in await state.exportBookmarksJSON() }
                } label: {
                    Label {
                        Text("Export to JSON…",
                             comment: "Settings — bookmarks export button")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button {
                    showingBulkPasteSheet = true
                } label: {
                    Label {
                        Text("Bulk paste…",
                             comment: "Settings — bookmarks bulk-paste button")
                    } icon: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "doc.text.magnifyingglass", titleKey: "Logs")
            Text("Open the LociiGhost log folder in Finder. Attach these files when you report a problem.",
                 comment: "Settings — Logs section explanation")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [LociiGhostPaths.logsDir]
                    )
                } label: {
                    Label {
                        Text("Reveal in Finder",
                             comment: "Settings — logs folder reveal button")
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                Button {
                    NSWorkspace.shared.open(LociiGhostPaths.logsDir)
                } label: {
                    Label {
                        Text("Open folder",
                             comment: "Settings — open logs folder button")
                    } icon: {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)

            Text(LociiGhostPaths.logsDir.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Geocoding

    private var geocodingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "globe.asia.australia", titleKey: "Geocoding")
            Text("When MapKit can't find a place (common for Chinese store / landmark names), LociiGhost can fall back to Google Geocoding using your own API key. Leave blank to disable.",
                 comment: "Settings — Geocoding section explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Google API key:",
                     comment: "Settings — Google API key field label")
                SecureField(
                    String(localized: "Paste your key here",
                           comment: "Settings — Google API key placeholder"),
                    text: $googleKeyDraft,
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                Button {
                    state.googleGeocodeAPIKey = googleKeyDraft
                    googleKeyDraft = state.googleGeocodeAPIKey ?? ""
                } label: {
                    Text("Save",
                         comment: "Settings — Google API key save button")
                }
                .buttonStyle(.borderedProminent)
                .disabled(googleKeyDraft.trimmingCharacters(in: .whitespaces)
                    == (state.googleGeocodeAPIKey ?? ""))
                if state.googleGeocodeAPIKey != nil {
                    Button(role: .destructive) {
                        googleKeyDraft = ""
                        state.googleGeocodeAPIKey = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help(LocalizedStringKey("Remove the saved Google API key"))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: state.googleGeocodeAPIKey == nil
                      ? "info.circle" : "checkmark.circle.fill")
                    .foregroundStyle(
                        state.googleGeocodeAPIKey == nil
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Color.green)
                    )
                Text(state.googleGeocodeAPIKey == nil
                     ? String(localized: "No key configured — search uses Apple MapKit only.",
                              comment: "Settings — Google geocoding status when no key")
                     : String(localized: "Key configured — Google is used as a fallback when MapKit returns no matches.",
                              comment: "Settings — Google geocoding status when a key is saved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://console.cloud.google.com/apis/library/geocoding-backend.googleapis.com")!) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("How to get a Google Geocoding API key",
                         comment: "Settings — link to Google Cloud API setup page")
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "bell.fill", titleKey: "Alerts")
            Text("Play the macOS system alert when a navigation, route loop, or random walk reaches its destination naturally. Explicit stops won't trigger the sound.",
                 comment: "Settings — Alerts section explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Toggle(isOn: Binding(
                    get: { state.alertSoundEnabled },
                    set: { state.alertSoundEnabled = $0 },
                )) {
                    Text("Play system sound on route complete",
                         comment: "Settings — toggle to enable route-complete sound")
                }
                Spacer()
                Button {
                    AlertSoundService.playRouteComplete()
                } label: {
                    Label {
                        Text("Test",
                             comment: "Settings — test play button for the route-complete sound")
                    } icon: {
                        Image(systemName: "play.circle.fill")
                    }
                }
                .buttonStyle(.bordered)
                .help(LocalizedStringKey("Preview the system alert sound"))
            }
        }
    }

    // MARK: - Routes (v1.9.1)

    /// Mirrors the Bookmarks section but acts on persisted Route
    /// records (GPX imports + JSON imports). GPX is the primary
    /// inbound format from external apps; JSON keeps the LociiGhost-
    /// to-LociiGhost round-trip exact (icon + category survive).
    private var routesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "point.bottomleft.forward.to.point.topright.scurvepath.fill",
                          titleKey: "Routes")
            Text("Multi-point tracks (GPX recordings or LociiGhost JSON exports). Use Import → GPX for trip files from other apps; JSON for round-tripping between LociiGhost machines.",
                 comment: "Settings — Routes section explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { @MainActor in await state.importGPX() }
                } label: {
                    Label {
                        Text("Import GPX…",
                             comment: "Settings — routes GPX import button")
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                Button {
                    Task { @MainActor in
                        if let msg = await state.importRoutesJSON() {
                            routesIOMessage = msg
                        }
                    }
                } label: {
                    Label {
                        Text("Import JSON…",
                             comment: "Settings — routes JSON import button")
                    } icon: {
                        Image(systemName: "square.and.arrow.down.on.square")
                    }
                }
                Button {
                    Task { @MainActor in
                        if let msg = await state.exportRoutesJSON() {
                            routesIOMessage = msg
                        }
                    }
                } label: {
                    Label {
                        Text("Export JSON…",
                             comment: "Settings — routes JSON export button")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)

            if let msg = routesIOMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.caption)
                    Text(msg)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(.blue.opacity(0.12), in: .rect(cornerRadius: 6))
                .transition(.opacity)
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(5))
                    if routesIOMessage == msg { routesIOMessage = nil }
                }
            }
        }
    }

    // MARK: - Routing engine (v1.9.1)

    /// User-facing routing-backend picker. Default is OSRM Public
    /// Demo (original behaviour). "Google Directions" reuses the
    /// Google API key from the Geocoding section above. "Straight
    /// line" skips routing entirely.
    private var routingEngineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "arrow.triangle.turn.up.right.diamond.fill",
                          titleKey: "Routing engine")
            Text("Which service plans your navigation routes. Pick the OSRM Public Demo to revert to the default.",
                 comment: "Settings — Routing engine section explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Use a Picker with stacked rows so each option's caption
            // is visible without hovering. Radio-style picker is the
            // macOS-native idiom for "pick one of N exclusive
            // backends".
            // Local Binding wrapper around `state.routingEngine`. We
            // use the get/set closure form here (rather than the
            // shorter `$state.routingEngine`) because Swift can't
            // infer Picker's SelectionValue generic when the
            // binding's wrapped type is a custom enum. This is safe
            // because `routingEngine` is now a stored @Observable
            // property (v1.9.3) — the closure just reads/writes
            // straight into observable storage, no computed-property
            // layer for the registrar to trip over.
            let engineBinding = Binding<RoutingEngine>(
                get: { state.routingEngine },
                set: { state.routingEngine = $0 },
            )
            Picker(selection: engineBinding) {
                ForEach(RoutingEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            } label: {
                Text("Engine:",
                     comment: "Settings — routing engine picker label")
            }
            .pickerStyle(.radioGroup)

            // Live caption + warnings under the current selection.
            VStack(alignment: .leading, spacing: 4) {
                Text(state.routingEngine.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.routingEngine == .google && state.googleGeocodeAPIKey == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Google Directions needs an API key — paste one into the Geocoding section above.",
                             comment: "Settings — Google routing engine selected but no key")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Troubleshooting (v1.9.1)

    /// "I'm stuck — kill everything and restart" panic button. Calls
    /// PrivilegedDaemonInstaller.install() under the hood: macOS auth
    /// prompts for sudo, then pkill nukes any surviving daemon
    /// processes (root + user) before a fresh one is spawned. The
    /// running app reconnects automatically through its bootstrap
    /// flow once the new socket appears.
    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(symbol: "wrench.and.screwdriver.fill",
                          titleKey: "Troubleshooting")
            Text("If LociiGhost stops responding (the daemon hangs, devices won't appear, navigation freezes), use this button to kill the daemon with admin privileges and start a clean one — no Terminal required.",
                 comment: "Settings — Troubleshooting section explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    Task { @MainActor in await state.forceRestartDaemon() }
                } label: {
                    Label {
                        Text("Force-kill & restart daemon",
                             comment: "Settings — force-restart button label")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help(LocalizedStringKey("Prompts for your macOS password, then force-kills any running daemon and starts a fresh one"))
                Spacer()
                if state.daemonStatus == .starting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Restarting…",
                             comment: "Settings — status next to Force Restart while daemon is starting back up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("You'll see a standard macOS authentication dialog. LociiGhost itself never reads your password.",
                     comment: "Settings — note about the macOS auth dialog under Force Restart")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - About / Credits (v1.9.2)

    /// Project identity + attribution. Anchored at the very bottom
    /// of the Settings sheet — discreet, not in the way, but always
    /// findable. Three pieces:
    ///   1. Project name + version
    ///   2. Author copyright (YCH81 / Jeff Hu, MIT)
    ///   3. Upstream attribution to LocWarp (MIT, keezxc1223) —
    ///      required by the upstream license; we also link to the
    ///      GitHub repo so a curious user can dig in.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(symbol: "info.circle", titleKey: "About")
            HStack(spacing: 6) {
                Image(systemName: "globe.asia.australia.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text("LociiGhost v\(AppState.expectedDaemonVersion)")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            Text("Copyright © 2026 YCH81 (Jeff Hu). Licensed under the MIT License.",
                 comment: "Settings — author copyright line")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 4) {
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundStyle(Color(red: 1.0, green: 0.369, blue: 0.357))
                    .font(.caption2)
                Link(
                    String(localized: "Support YCH81 (aka Jeff Hu) on Ko-fi",
                           comment: "Settings — Ko-fi support link"),
                    destination: URL(string: "https://ko-fi.com/jflociighost")!
                )
                .font(.caption)
                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Image(systemName: "message.fill")
                    .foregroundStyle(Color(red: 0.024, green: 0.780, blue: 0.333))
                    .font(.caption2)
                Link(
                    String(localized: "LINE Official Account @382ydavk",
                           comment: "Settings — LINE Official Account link"),
                    destination: URL(string: "https://line.me/R/ti/p/%40382ydavk")!
                )
                .font(.caption)
                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Text("Inspired by ",
                     comment: "Settings — upstream attribution prefix")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    String(localized: "LocWarp",
                           comment: "Settings — upstream project name (link)"),
                    destination: URL(string: "https://github.com/keezxc1223/locwarp")!
                )
                .font(.caption)
                Text(" by keezxc1223 (MIT). LociiGhost is a complete native-Swift rewrite.",
                     comment: "Settings — upstream attribution suffix")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)

            Text("Run `cat LICENSE` from the project root for the full MIT text with both copyright notices.",
                 comment: "Settings — pointer to LICENSE file")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(symbol: String, titleKey: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
            Text(titleKey)
                .font(.headline)
            Spacer()
        }
    }
}
