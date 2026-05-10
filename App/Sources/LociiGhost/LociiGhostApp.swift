import SwiftUI
import SwiftData
import LociiGhostCore

/// User-selectable UI language. `system` means "follow whatever
/// macOS would have chosen" — read from `Locale.autoupdatingCurrent`
/// at runtime so a system-wide language change while the app is
/// running takes effect on the next view update without us doing
/// anything special. The two explicit cases (`en`, `zhHant`) override
/// that with a fixed `Locale`. Persisted via `@AppStorage` so the
/// choice survives app relaunch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case en
    case zhHant = "zh-Hant"

    var id: String { rawValue }

    /// The Locale we feed into `.environment(\.locale, ...)`. SwiftUI
    /// `Text("literal")` resolution honours this since macOS 14 /
    /// iOS 17, so a language switch propagates through the UI on the
    /// next render — no app restart needed.
    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .en:     return Locale(identifier: "en")
        case .zhHant: return Locale(identifier: "zh-Hant")
        }
    }

    /// The label shown next to the radio in the language picker.
    /// For the explicit languages we use the language's OWN name
    /// rather than localising the label (so a user who can't read
    /// the current UI language can still find their language).
    var displayName: String {
        switch self {
        case .system: return String(localized: "Follow System",
                                    comment: "Language picker option that defers to macOS's language preference")
        case .en:     return "English"
        case .zhHant: return "繁體中文"
        }
    }
}

@main
struct LociiGhostApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Persisted user language choice. Default `.system` defers to
    /// the macOS-wide language preference — so a fresh install Just
    /// Works for both English and zh-Hant users without them touching
    /// the picker.
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system

    /// SwiftData container holding `AppPreferences` (Phase 5.2) and
    /// future bookmarks (Phase 5.3). Stored under the same Application
    /// Support directory the daemon uses, so a "wipe LociiGhost" via
    /// the cleanup script clears app preferences too. We force the
    /// store URL explicitly so the file ends up in the LociiGhost
    /// folder rather than SwiftData's default `~/Library/Containers/...`
    /// path.
    private let modelContainer: ModelContainer = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LociiGhost", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "preferences.store")
        let config = ModelConfiguration(url: url)
        do {
            return try ModelContainer(for: AppPreferences.self, configurations: config)
        } catch {
            // If the store is unreadable (schema change, corruption),
            // drop back to an in-memory store so the app still launches
            // — the user just loses persisted prefs for this session.
            NSLog("LociiGhost: SwiftData container failed (%@); falling back to in-memory",
                  String(describing: error))
            let mem = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: AppPreferences.self, configurations: mem)
        }
    }()

    var body: some Scene {
        WindowGroup("LociiGhost") {
            MainView()
                .environment(appState)
                .environment(\.locale, appLanguage.locale)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    AppDelegate.sharedAppState = appState
                    appState.attachModelContext(modelContainer.mainContext)
                    await appState.bootstrap()
                    // macOS hands keyboard focus to the first focusable
                    // text field when a SwiftUI window opens — that's
                    // our search bar, which then captures stray
                    // keystrokes the user expected to be controls or
                    // joystick keys. Drop the first responder so the
                    // window starts with no focused field.
                    NSApp.windows.first?.makeFirstResponder(nil)
                }
        }
        .modelContainer(modelContainer)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}        // hide File > New
        }
        // Standard Cmd-, opens our SettingsView.
        Settings {
            SettingsView(appLanguage: $appLanguage)
                .environment(appState)
        }
    }
}

