import SwiftUI
import LociiGhostCore

@main
struct LociiGhostApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("LociiGhost") {
            MainView()
                .environment(appState)
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
    }
}
