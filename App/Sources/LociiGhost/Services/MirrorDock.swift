import AppKit
import ApplicationServices
import Observation
import LociiGhostCore

/// Docks macOS's built-in **iPhone Mirroring** window to the side of
/// the LociiGhost window, so you can drive the phone on your Mac
/// while LociiGhost is feeding it a fake location.
///
/// ## Why it works this way
///
/// There is no public API to embed another application's window.
/// `NSWindow.addChildWindow` is same-process only, and the window
/// server will not let one app reparent another's surface. Screen-
/// scraping it (ScreenCaptureKit) and forwarding synthetic clicks
/// *would* let us paint the phone inside our own view, but it costs a
/// capture + encode + composite round-trip per frame and turns every
/// tap into a `CGEvent` — which is exactly the latency you don't want
/// when the point of the feature is playing a game.
///
/// So we keep Apple's window, with Apple's native input path (taps go
/// straight from the window server to iPhone Mirroring — we are not in
/// that loop at all), and use the Accessibility API to *glue* it to
/// our window edge: launch it, find its window, move it flush against
/// our frame, and keep it there as our window moves, resizes,
/// miniaturises or hides.
///
/// The two windows are deliberately laid out **side by side, never
/// overlapping**. Overlap would mean fighting the window server over
/// z-order every time focus changed between two separate processes,
/// which is unwinnable; adjacency makes z-order irrelevant.
///
/// ## What this needs from the user
///
/// One TCC grant: System Settings → Privacy & Security → Accessibility.
/// Without it every `AXUIElement…` call returns `kAXErrorAPIDisabled`
/// and we can see nothing. The grant is keyed to the app binary, so a
/// rebuilt/re-signed LociiGhost has to be re-approved.
@MainActor
@Observable
final class MirrorDock {

    // MARK: - Types

    enum Status: Equatable {
        /// This Mac has no iPhone Mirroring.app (pre-Sequoia, or an
        /// installation where it was removed).
        case unsupported
        /// Off — the user hasn't turned the dock on.
        case off
        /// Turned on, but we can't read windows until the user grants
        /// Accessibility.
        case needsPermission
        /// Launch requested; iPhone Mirroring hasn't put a window up
        /// yet (it may be showing its own "unlock your iPhone" step).
        case waitingForWindow
        /// Glued and following.
        case docked
        /// Something went wrong that retrying won't fix on its own.
        case failed(String)
    }

    /// Bundle id of the system iPhone Mirroring app. Stable since
    /// macOS 15 — the app's marketing name changed at one point, the
    /// bundle id did not.
    nonisolated static let mirrorBundleID = "com.apple.ScreenContinuity"

    private enum Key {
        static let enabled = "mirrorDockEnabled"
        static let edge = "mirrorDockEdge"
    }

    // MARK: - Observable state

    private(set) var status: Status = .off

    /// Which side the phone sits on. Persisted; changing it re-snaps
    /// immediately.
    var edge: MirrorDockEdge {
        didSet {
            guard edge != oldValue else { return }
            UserDefaults.standard.set(edge.rawValue, forKey: Key.edge)
            snap(force: true)
        }
    }

    /// Last size we read back from the mirror window. Surfaced in the
    /// UI because it's the number that explains the layout — the
    /// mirror's size is Apple's to choose, not ours.
    private(set) var mirrorSize: CGSize = .zero

    /// `nil` until we've tried once. `false` means iPhone Mirroring
    /// refused an `AXSize` write, so the height is whatever its own
    /// View menu (Actual Size / Larger / Smaller) is set to and the
    /// user has to change it there.
    private(set) var mirrorSizeIsSettable: Bool?

    /// False when the app window + the mirror are together wider than
    /// the display. The dock still works, but the windows overlap.
    private(set) var fitsOnScreen: Bool = true

    /// The last placement calculation, as text.
    ///
    /// This is not debug scaffolding to be removed later. The layout
    /// spans two coordinate systems and however many displays the
    /// user has plugged in, and when it goes wrong the only thing
    /// visible is "the window is in the wrong place" -- which is
    /// consistent with a dozen different causes. One line of numbers
    /// in the popover turns a bug report into an answer.
    private(set) var diagnostics: String = ""

    var isEnabled: Bool { status != .off && status != .unsupported }

    // MARK: - Private state

    private var pollTimer: Timer?
    private var localObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Guards against the move we just performed re-entering through
    /// `NSWindow.didMoveNotification` and starting a snap cascade.
    private var isApplyingLayout = false
    private var mirrorAppElement: AXUIElement?
    private var mirrorPID: pid_t = 0
    /// Set once per dock session so we only make one speculative
    /// resize attempt instead of fighting the app every tick.
    private var didAttemptResize = false

    // MARK: - Lifecycle

    init() {
        let raw = UserDefaults.standard.string(forKey: Key.edge) ?? MirrorDockEdge.right.rawValue
        self.edge = MirrorDockEdge(rawValue: raw) ?? .right
        if Self.mirrorAppURL == nil {
            status = .unsupported
        }
    }

    /// Called from `AppState.bootstrap()`. Restores the dock if the
    /// user left it on last time — but silently, without ever
    /// throwing the Accessibility prompt at someone who just wanted
    /// to open the app.
    func restoreIfPreviouslyEnabled() {
        guard status != .unsupported else { return }
        guard UserDefaults.standard.bool(forKey: Key.enabled) else { return }
        guard AXIsProcessTrusted() else {
            // Remember the preference, but don't nag on launch.
            status = .needsPermission
            return
        }
        enable(promptForPermission: false)
    }

    /// Turn the dock on: request Accessibility if we don't have it,
    /// launch iPhone Mirroring without stealing focus, then start
    /// following.
    ///
    /// - Parameter promptForPermission: show macOS's "open System
    ///   Settings" Accessibility prompt when the grant is missing.
    ///   True for a user-initiated toggle, false on app launch.
    func enable(promptForPermission: Bool = true) {
        guard let appURL = Self.mirrorAppURL else {
            status = .unsupported
            return
        }
        UserDefaults.standard.set(true, forKey: Key.enabled)

        guard Self.hasAccessibility(prompt: promptForPermission) else {
            status = .needsPermission
            return
        }

        status = .waitingForWindow
        didAttemptResize = false
        mirrorAppElement = nil
        mirrorPID = 0

        let config = NSWorkspace.OpenConfiguration()
        // Do NOT pull focus. The user clicked a button in our window;
        // yanking them into another app would be rude, and the dock
        // looks the same either way.
        config.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.status = .failed(error.localizedDescription)
            }
        }

        installObservers()
        startPolling()
        snap(force: true)
    }

    /// Turn the dock off. Hides iPhone Mirroring rather than quitting
    /// it: hiding is instant to undo and keeps the phone session
    /// alive, so flipping the dock back on doesn't make the user
    /// re-unlock their iPhone.
    func disable() {
        UserDefaults.standard.set(false, forKey: Key.enabled)
        stopPolling()
        removeObservers()
        Self.runningMirrorApp()?.hide()
        mirrorAppElement = nil
        mirrorPID = 0
        mirrorSizeIsSettable = nil
        mirrorSize = .zero
        fitsOnScreen = true
        status = Self.mirrorAppURL == nil ? .unsupported : .off
    }

    func toggle() {
        if isEnabled { disable() } else { enable() }
    }

    /// Quit iPhone Mirroring outright. Offered separately from
    /// `disable()` because ending the phone session is a bigger deal
    /// than putting the window away.
    func quitMirrorApp() {
        Self.runningMirrorApp()?.terminate()
        if isEnabled { disable() }
    }

    /// Called from `AppDelegate.applicationShouldTerminate`. Leaves
    /// the preference alone so the dock comes back next launch, but
    /// gets the orphaned window off the user's screen.
    func detachForAppExit() {
        stopPolling()
        removeObservers()
        if isEnabled { Self.runningMirrorApp()?.hide() }
    }

    /// Opens the exact Settings pane the user needs. We never flip
    /// the switch for them — TCC wouldn't allow it, and it shouldn't.
    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Re-check the grant after the user has been to System Settings.
    func recheckPermission() {
        guard status == .needsPermission else { return }
        if AXIsProcessTrusted() {
            enable(promptForPermission: false)
        }
    }

    // MARK: - Following

    private func startPolling() {
        stopPolling()
        // 0.35s: fast enough that a window the user just dragged
        // snaps back before it reads as broken, slow enough that a
        // handful of AX round-trips per second is invisible in
        // Activity Monitor. The notification observers below carry
        // the interactive cases; this timer exists for the ones
        // AppKit never tells us about (the mirror window appearing,
        // the user dragging *it*, a display being unplugged).
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.snap(force: false) }
        }
        // .common so the snap keeps running while a menu is open or
        // the user is mid-drag on our own window.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func installObservers() {
        removeObservers()
        let nc = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            localObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.snap(force: true) }
            })
        }
        let wnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(wnc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main,
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == MirrorDock.mirrorBundleID else { return }
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                // The user closed the mirror window themselves. Treat
                // that as "off" rather than relaunching it in a loop.
                self.disable()
            }
        })
    }

    private func removeObservers() {
        for o in localObservers { NotificationCenter.default.removeObserver(o) }
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        localObservers.removeAll()
        workspaceObservers.removeAll()
    }

    /// The heart of it: read both windows, compute the target, write
    /// it back if it drifted.
    ///
    /// - Parameter force: skip the "did anything change?" shortcut.
    ///   Used when the reason we're here is a move/resize we already
    ///   know about.
    private func snap(force: Bool) {
        guard isEnabled, status != .needsPermission else { return }
        guard !isApplyingLayout else { return }

        // Never fight the user's own drag. `pressedMouseButtons` is a
        // cheap global read; while a button is down we let both
        // windows go wherever they're being dragged and re-glue on
        // mouse-up (the next tick).
        if !force, NSEvent.pressedMouseButtons != 0 { return }

        guard let running = Self.runningMirrorApp() else {
            if status != .waitingForWindow { status = .waitingForWindow }
            return
        }

        // The mirror follows our window's visibility. Deciding it
        // here, from the current state, rather than from a fan of
        // didHide / didMiniaturize / willClose notifications, means
        // one rule covers every way our window can go away — and
        // there's no state to get stuck in if two of those arrive
        // out of order.
        let appWindow = Self.mainAppWindow()
        let appIsOnScreen = !NSApp.isHidden
            && (appWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false)
        if !appIsOnScreen {
            if !running.isHidden { running.hide() }
            return
        }
        if running.isHidden { running.unhide() }

        guard let appWindow else { return }
        guard let mirrorWindow = resolveMirrorWindow() else {
            if status != .waitingForWindow { status = .waitingForWindow }
            return
        }

        guard let currentMirrorSize = AXBridge.size(of: mirrorWindow) else { return }
        mirrorSize = currentMirrorSize

        guard let screenNS = appWindow.screen ?? NSScreen.main else { return }
        let screenAX = AXBridge.toAX(rect: screenNS.visibleFrame)
        let appAX = AXBridge.toAX(rect: appWindow.frame)

        isApplyingLayout = true
        defer { isApplyingLayout = false }

        // First pass: one speculative write to find out whether
        // this macOS release lets us size the mirror at all. After
        // that we only keep trying while the answer was yes — so a
        // release that refuses gets asked exactly once, and one that
        // accepts stays glued to our height as the user resizes us.
        var effectiveSize = currentMirrorSize
        if !didAttemptResize || mirrorSizeIsSettable == true {
            if let want = MirrorDockGeometry.aspectFittedSize(
                current: currentMirrorSize,
                targetHeight: appAX.height,
                maxHeight: screenAX.height,
            ), abs(want.height - currentMirrorSize.height) > 4 {
                AXBridge.setSize(want, on: mirrorWindow)
                let after = AXBridge.size(of: mirrorWindow) ?? currentMirrorSize
                let moved = abs(after.height - currentMirrorSize.height) > 2
                // A "yes" that stops being true (the window hits its
                // own min/max, the app changes behaviour) demotes
                // itself here, so we can never spin writing a size
                // the app keeps rejecting.
                mirrorSizeIsSettable = moved
                effectiveSize = after
                mirrorSize = after
            } else if !didAttemptResize {
                // Already the right height — no evidence either way.
                mirrorSizeIsSettable = nil
            }
            didAttemptResize = true
        }

        let placement = MirrorDockGeometry.place(
            app: appAX,
            mirrorSize: effectiveSize,
            screen: screenAX,
            edge: edge,
        )
        fitsOnScreen = placement.fits

        func r(_ v: CGFloat) -> String { String(Int(v.rounded())) }
        diagnostics = "app \(r(appAX.minX)),\(r(appAX.minY)) \(r(appAX.width))×\(r(appAX.height))"
            + "  screen \(r(screenAX.minX)),\(r(screenAX.minY)) \(r(screenAX.width))×\(r(screenAX.height))"
            + "  → mirror \(r(placement.mirrorOrigin.x)),\(r(placement.mirrorOrigin.y))"
            + (placement.appOrigin.map { "  move app → \(r($0.x))" } ?? "  app stays")

        if let appOrigin = placement.appOrigin {
            let nsOrigin = AXBridge.toAppKit(
                origin: appOrigin, size: appAX.size,
            )
            if abs(nsOrigin.x - appWindow.frame.origin.x) > 1
                || abs(nsOrigin.y - appWindow.frame.origin.y) > 1 {
                appWindow.setFrameOrigin(nsOrigin)
            }
        }

        let currentOrigin = AXBridge.position(of: mirrorWindow) ?? .zero
        if force
            || abs(currentOrigin.x - placement.mirrorOrigin.x) > 1
            || abs(currentOrigin.y - placement.mirrorOrigin.y) > 1 {
            AXBridge.setPosition(placement.mirrorOrigin, on: mirrorWindow)
        }

        if status != .docked { status = .docked }
    }

    // MARK: - Accessibility plumbing

    /// Finds the mirror app's main window, caching the application
    /// element across ticks (creating it is cheap, but the pid lookup
    /// isn't free and this runs ~3x/second).
    private func resolveMirrorWindow() -> AXUIElement? {
        guard let running = Self.runningMirrorApp() else {
            mirrorAppElement = nil
            mirrorPID = 0
            return nil
        }
        if mirrorAppElement == nil || mirrorPID != running.processIdentifier {
            mirrorPID = running.processIdentifier
            let element = AXUIElementCreateApplication(running.processIdentifier)
            // Cap every AX round-trip. Without this a wedged iPhone
            // Mirroring (it does wedge while the phone is
            // reconnecting) would block our main thread for the
            // system default of 6 seconds — i.e. hang the UI.
            _ = AXUIElementSetMessagingTimeout(element, 0.4)
            mirrorAppElement = element
            didAttemptResize = false
        }
        guard let appElement = mirrorAppElement else { return nil }
        let windows = AXBridge.windows(of: appElement)
        // iPhone Mirroring can briefly own more than one window (its
        // onboarding sheet, the "unlock iPhone to continue" panel).
        // The phone screen is always the biggest of them.
        return windows.max(by: { lhs, rhs in
            let l = AXBridge.size(of: lhs) ?? .zero
            let r = AXBridge.size(of: rhs) ?? .zero
            return l.width * l.height < r.width * r.height
        })
    }

    // MARK: - Statics

    /// `nil` on a Mac without iPhone Mirroring, which is how the UI
    /// decides whether to show the feature at all.
    static let mirrorAppURL: URL? = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mirrorBundleID) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/System/Applications/iPhone Mirroring.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }()

    static func runningMirrorApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: mirrorBundleID).first
    }

    static func hasAccessibility(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        // The SDK exposes `kAXTrustedCheckOptionPrompt` as a mutable
        // global, which Swift 6 refuses to let us touch across
        // isolation. Its value is a documented, stable constant, so
        // we spell it out rather than smuggling the symbol through
        // an `nonisolated(unsafe)` shim.
        return AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary,
        )
    }

    /// Our own main window. `NSApp.windows` also contains panels,
    /// popovers and the Settings scene, so we take the first visible
    /// one that's big enough to be the real thing.
    private static func mainAppWindow() -> NSWindow? {
        if let main = NSApp.mainWindow, main.isVisible, main.frame.width > 600 { return main }
        return NSApp.windows.first { $0.isVisible && $0.frame.width > 600 }
    }
}

// MARK: - AXUIElement helpers

/// Thin, failure-tolerant wrapper over the C Accessibility API, plus
/// the one coordinate flip the rest of the feature depends on.
///
/// AppKit measures from the **bottom-left of the primary display with
/// y growing up**; Accessibility measures from the **top-left of the
/// primary display with y growing down**. Every AX rectangle in this
/// file is in the latter space, and these two functions are the only
/// place the conversion happens.
@MainActor
enum AXBridge {

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &value,
        ) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(of window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &value,
        ) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    @discardableResult
    static func setPosition(_ point: CGPoint, on window: AXUIElement) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, value,
        ) == .success
    }

    @discardableResult
    static func setSize(_ size: CGSize, on window: AXUIElement) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, value,
        ) == .success
    }

    /// Height of the coordinate space AppKit and AX disagree about:
    /// the top edge of the primary display. `NSScreen.screens[0]` is
    /// documented as the screen containing the menu bar, whose frame
    /// origin is (0, 0) — the same origin AX flips around.
    private static var primaryTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// AppKit rect -> AX rect.
    static func toAX(rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryTop - rect.maxY,
            width: rect.width,
            height: rect.height,
        )
    }

    /// AX origin (+ the size that goes with it) -> AppKit origin.
    static func toAppKit(origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: origin.x, y: primaryTop - origin.y - size.height)
    }
}
