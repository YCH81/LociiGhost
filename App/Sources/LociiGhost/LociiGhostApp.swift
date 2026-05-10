import SwiftUI
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

    var body: some Scene {
        WindowGroup("LociiGhost") {
            MainView()
                .environment(appState)
                .environment(\.locale, appLanguage.locale)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    AppDelegate.sharedAppState = appState
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

