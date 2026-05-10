import SwiftUI

/// Sidebar block that exposes the alternate movement modes
/// (joystick / random walk / multi-stop). Sits above System Functions
/// in the sidebar. Selecting a mode reveals its controls **inline**,
/// underneath the mode-button row, so the user never leaves the
/// sidebar to configure or operate a mode.
struct MovementModesSection: View {
    @Environment(AppState.self) private var state
    @State private var activeMode: Mode?

    enum Mode: Hashable, Identifiable {
        case joystick
        case randomWalk
        case multiStop
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Movement Modes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                modeButton(.joystick,
                           symbol: "gamecontroller.fill",
                           title: LocalizedStringKey("Joystick"))
                modeButton(.randomWalk,
                           symbol: "shuffle.circle.fill",
                           title: LocalizedStringKey("Random"))
                modeButton(.multiStop,
                           symbol: "list.bullet.indent",
                           title: LocalizedStringKey("Multi-stop"))
            }

            if let mode = activeMode {
                Divider().padding(.vertical, 2)
                Group {
                    switch mode {
                    case .joystick:   JoystickPanel()
                    case .randomWalk: RandomWalkPanel()
                    case .multiStop:  MultiStopPanel()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: activeMode)
    }

    private func modeButton(_ mode: Mode, symbol: String, title: LocalizedStringKey) -> some View {
        let isActive = activeMode == mode
        return Button {
            activeMode = isActive ? nil : mode
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                isActive ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                         : AnyShapeStyle(Color.secondary.opacity(0.06)),
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .disabled(state.selectedUDID == nil)
        .help(state.selectedUDID == nil
              ? LocalizedStringKey("Select a device first.")
              : title)
    }
}
