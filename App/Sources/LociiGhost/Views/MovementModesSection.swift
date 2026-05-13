import SwiftUI

/// Sidebar block that exposes the alternate movement modes
/// (joystick / random walk / multi-stop). Sits above System Functions
/// in the sidebar. Selecting a mode reveals its controls **inline**,
/// underneath the mode-button row, so the user never leaves the
/// sidebar to configure or operate a mode.
struct MovementModesSection: View {
    @Environment(AppState.self) private var state
    @State private var sectionCollapsed: Bool = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk.motion")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text("Movement Modes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: sectionCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .contentShape(.rect)
            .hoverHighlight(cornerRadius: 4, changesCursor: false)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sectionCollapsed.toggle()
                }
            }

            if !sectionCollapsed {
                // Four-mode row. Gold Ditto is the newest addition
                // (v1.4) — it's a Pikmin Bloom-specific exploit so
                // we keep it last in the row; users who don't play
                // that game can ignore it without it eating prime
                // real estate.
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
                    modeButton(.goldDitto,
                               symbol: "sparkles",
                               title: LocalizedStringKey("Gold Ditto"))
                }

                if let mode = state.activeMovementMode {
                    Divider().padding(.vertical, 2)
                    Group {
                        switch mode {
                        case .joystick:   JoystickPanel()
                        case .randomWalk: RandomWalkPanel()
                        case .multiStop:  MultiStopPanel()
                        case .goldDitto:  GoldDittoPanel()
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.activeMovementMode)
    }

    private func modeButton(_ mode: MovementMode, symbol: String, title: LocalizedStringKey) -> some View {
        let isActive = state.activeMovementMode == mode
        return Button {
            state.activeMovementMode = isActive ? nil : mode
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(isActive ? Color.lociSage : Color.secondary)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Color.lociSage : Color.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                isActive ? AnyShapeStyle(Color.lociSage.opacity(0.14))
                         : AnyShapeStyle(Color.secondary.opacity(0.06)),
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 6, changesCursor: false)
        .disabled(state.selectedUDID == nil || state.isVirtualMapSelected)
        .help(state.selectedUDID == nil
              ? LocalizedStringKey("Select a device first.")
              : (state.isVirtualMapSelected
                 ? LocalizedStringKey("Switch to a connected iPhone to use movement modes.")
                 : title))
    }
}
