import AppKit
import SwiftUI
import LociiGhostCore

/// Inline joystick controller for the sidebar. Same key-capture trick
/// the sheet version used (an invisible focused TextField + onKeyPress)
/// — but compact enough to live in a 260-pt sidebar slot.
struct JoystickPanel: View {
    @Environment(AppState.self) private var state

    @State private var keysHeld: Set<MoveKey> = []

    private var session: JoystickVM? { state.joystick }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Heading wheel —————————————————————————————————————
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                Circle()
                    .fill(headingColor.opacity(0.18))
                    .scaleEffect(0.55)
                arrowGlyph
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)

            Text(statusText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
                .truncationMode(.middle)

            // Speed selection (shared) ——————————————————————————
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed").font(.caption.weight(.medium))
                SpeedPicker()
            }

            // Key capture (invisible) and instructions
            keyCapture

            // Action row —————————————————————————————————————————
            actionRow
        }
    }

    // MARK: -

    private var headingColor: Color {
        keysHeld.isEmpty ? .secondary : .accentColor
    }

    @ViewBuilder
    private var arrowGlyph: some View {
        if let h = MoveKey.heading(of: keysHeld) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(h))
        } else {
            Image(systemName: "circle.dashed")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if session == nil {
            return "Press Start, then hold W/A/S/D to drive."
        }
        if keysHeld.isEmpty {
            return "idle · release-to-stop"
        }
        let h = Int(MoveKey.heading(of: keysHeld) ?? 0)
        let kmh = (state.customSpeedMps ?? state.travelProfile.defaultSpeedMps) * 3.6
        return String(format: "moving · %d° · %.1f km/h", h, kmh)
    }

    @ViewBuilder
    private var keyCapture: some View {
        if session != nil {
            JoystickKeyMonitor(keysHeld: $keysHeld) { headingDeg, isMoving in
                Task {
                    guard let udid = state.selectedUDID else { return }
                    let speed = isMoving
                        ? (state.customSpeedMps ?? state.travelProfile.defaultSpeedMps)
                        : 0
                    await state.updateJoystick(udid: udid,
                                               headingDeg: headingDeg,
                                               speedMps: speed)
                }
            }
            .frame(width: 0, height: 0)
        } else {
            Text("Press Start, then hold **W A S D** or arrow keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if session != nil {
            Button(role: .destructive) {
                if let udid = state.selectedUDID {
                    Task { await state.stopJoystick(udid: udid) }
                }
                keysHeld.removeAll()
            } label: {
                Label("Stop Joystick", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                Task { await begin() }
            } label: {
                Label("Start Joystick", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
        }
    }

    private var canStart: Bool {
        guard let udid = state.selectedUDID,
              state.devices.first(where: { $0.udid == udid })?.connected == true
        else { return false }
        return true
    }

    private func begin() async {
        guard let udid = state.selectedUDID else { return }
        let origin: Coordinate = state.simulatedLocation
            ?? state.macLocation.coordinate.map { Coordinate(lat: $0.latitude, lng: $0.longitude) }
            ?? Coordinate(lat: 25.0330, lng: 121.5654)
        await state.startJoystick(udid: udid, origin: origin)
    }
}

// MARK: - MoveKey

/// Discrete cardinal directions corresponding to W/A/S/D + arrow keys.
/// Multiple held keys combine into a heading angle via `heading(of:)`.
enum MoveKey: Hashable {
    case north, south, east, west

    /// Combine all currently-held arrow / WASD keys into a single
    /// heading in degrees (0 = N, 90 = E, 180 = S, 270 = W). Returns
    /// nil if no movement keys are pressed.
    static func heading(of keys: Set<MoveKey>) -> Double? {
        if keys.isEmpty { return nil }
        var dx = 0.0
        var dy = 0.0
        if keys.contains(.north) { dy += 1 }
        if keys.contains(.south) { dy -= 1 }
        if keys.contains(.east)  { dx += 1 }
        if keys.contains(.west)  { dx -= 1 }
        if dx == 0 && dy == 0 { return nil }
        let angle = atan2(dx, dy) * 180.0 / .pi
        return (angle + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}

// MARK: - Key capture via NSEvent local monitor

/// Hook the global NSEvent flow while the joystick session is active so
/// W/A/S/D and the arrow keys reach us regardless of which view holds
/// first responder. SwiftUI's `.onKeyPress` on a hidden TextField was
/// unreliable here — the field would consume the keystroke as text and
/// `.onKeyPress(.up)` events were inconsistent.
///
/// The monitor is installed in `makeNSView` and torn down in the
/// coordinator's `deinit`, so it lives exactly as long as this view is
/// in the hierarchy. When the user closes the joystick session, this
/// view goes away and the monitor is removed — WASD elsewhere in the
/// app behaves normally again.
private struct JoystickKeyMonitor: NSViewRepresentable {
    @Binding var keysHeld: Set<MoveKey>
    let onChange: (Double, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Don't fight modifier shortcuts (Cmd-W, Cmd-A, etc.) — let
            // them reach the system normally.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) || mods.contains(.option) || mods.contains(.control) {
                return event
            }
            // If the user is typing into a real text field elsewhere
            // (search bar, custom-speed input, etc.), don't steal their
            // keystrokes.
            if let fr = event.window?.firstResponder, fr is NSTextView {
                return event
            }
            guard let key = Self.map(event) else { return event }
            let isDown = event.type == .keyDown && !event.isARepeat
            let isRepeat = event.type == .keyDown && event.isARepeat
            // Ignore key-repeat: we don't want each auto-repeat tick to
            // re-insert the key (it's already in the set).
            if isRepeat { return nil }
            DispatchQueue.main.async {
                if isDown {
                    keysHeld.insert(key)
                } else {
                    keysHeld.remove(key)
                }
                let heading = MoveKey.heading(of: keysHeld) ?? 0
                onChange(heading, !keysHeld.isEmpty)
            }
            return nil           // swallow so it doesn't bubble elsewhere
        }
        context.coordinator.monitor = monitor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor {
            NSEvent.removeMonitor(m)
            coordinator.monitor = nil
        }
    }

    final class Coordinator {
        var monitor: Any?
        deinit {
            if let m = monitor {
                NSEvent.removeMonitor(m)
            }
        }
    }

    private static func map(_ event: NSEvent) -> MoveKey? {
        // Match by character first (handles Dvorak / non-QWERTY too) and
        // fall back to physical key codes for the arrow keys, which have
        // no useful character mapping.
        if let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "w": return .north
            case "s": return .south
            case "a": return .west
            case "d": return .east
            default: break
            }
        }
        switch event.keyCode {
        case 126: return .north    // up arrow
        case 125: return .south    // down arrow
        case 123: return .west     // left arrow
        case 124: return .east     // right arrow
        default:  return nil
        }
    }
}
