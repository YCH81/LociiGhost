import AppKit
import SwiftUI

/// Hooks into AppKit's app-lifecycle so the app behaves like a normal Mac
/// utility:
///
/// 1. Closing the last window quits the process. SwiftUI's default keeps the
///    app alive in the Dock with no window, which here just means a stale
///    socket connection nobody can interact with -- not useful.
/// 2. Re-clicking the Dock icon (or Spotlight) when no window is open
///    re-creates the main window so the user can come back without quitting
///    and re-launching.
/// 3. `applicationWillTerminate` waits for the AppState to flush its
///    socket connection cleanly. The daemon itself is left alone if it was
///    attached to externally (sudo-launched), so the user doesn't pay the
///    sudo prompt on the next launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `LocWarpMacApp` so we can drive teardown from the delegate.
    @MainActor static weak var sharedAppState: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible {
            // Tell SwiftUI to re-open the default scene. This works because
            // we only have one WindowGroup.
            for window in sender.windows where !window.isVisible {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = AppDelegate.sharedAppState else { return .terminateNow }
        Task { @MainActor in
            await state.teardown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
