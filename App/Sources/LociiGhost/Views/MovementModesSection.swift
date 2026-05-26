import SwiftUI

/// Sidebar block that exposes the alternate movement modes
/// (joystick / random walk / multi-stop). Sits above System Functions
/// in the sidebar. Selecting a mode reveals its controls **inline**,
/// underneath the mode-button row, so the user never leaves the
/// sidebar to configure or operate a mode.
struct MovementModesSection: View {
    @Environment(AppState.self) private var state
    @State private var sectionCollapsed: Bool = false
    /// Holds the user's mode-switch request while we wait on the
    /// "Stop current route?" confirmation alert. nil means no pending
    /// switch. The wrapper's `target` is itself optional because
    /// "turn off the current mode" is a legitimate switch (target ==
    /// nil) we still want to confirm.
    @State private var pendingSwitch: PendingSwitch?

    private struct PendingSwitch: Identifiable {
        let id = UUID()
        let target: MovementMode?
    }

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
                               title: LocalizedStringKey("Multi-stop"),
                               blockedByRoute: state.navigationActive && state.activeMovementMode != .multiStop)
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
        .alert(
            String(localized: "Stop current simulation?",
                   comment: "Mode-switch confirmation title — user has an active simulation (navigation / random walk / joystick)"),
            isPresented: Binding(
                get: { pendingSwitch != nil },
                set: { if !$0 { pendingSwitch = nil } }
            ),
            presenting: pendingSwitch,
        ) { pending in
            Button(role: .cancel) {
                pendingSwitch = nil
            } label: {
                Text("Keep going",
                     comment: "Mode-switch confirmation cancel button — keep the current route running")
            }
            Button(role: .destructive) {
                let target = pending.target
                pendingSwitch = nil
                if let udid = state.selectedUDID {
                    Task {
                        // Stop whichever live session(s) are running.
                        // Multiple can technically be set in pathological
                        // states (race during a prior switch) — stop them
                        // all so we land in a clean slate before
                        // activating the new mode.
                        if state.navigationActive {
                            await state.stopNavigation(udid: udid)
                        }
                        if state.randomWalkActive {
                            await state.stopRandomWalk(udid: udid)
                        }
                        if state.joystickActive {
                            await state.stopJoystick(udid: udid)
                        }
                        await MainActor.run {
                            state.activeMovementMode = target
                        }
                    }
                } else {
                    state.activeMovementMode = target
                }
            } label: {
                Text("Stop & switch",
                     comment: "Mode-switch confirmation destructive button — stops the active session then switches mode")
            }
        } message: { _ in
            Text("Switching modes ends the current simulation. The iPhone halts at its current simulated position.",
                 comment: "Mode-switch confirmation message — applies to navigation / random walk / joystick")
        }
    }

    /// Any active simulation session whose interruption deserves a
    /// "Stop current X?" prompt before mode-switching: live navigation
    /// (multi-stop / route), random walker, or joystick. Gold Ditto
    /// doesn't have a long-running session — its actions are one-shot
    /// — so it doesn't gate switching.
    // Reads cheap session-active booleans that only flip on session
    // start/stop — NOT on every 1 Hz position event. Keeps the mode
    // buttons from re-rendering while a simulation is running.
    private var hasActiveSession: Bool { state.anySessionActive }

    private func modeButton(_ mode: MovementMode, symbol: String, title: LocalizedStringKey,
                             blockedByRoute: Bool = false) -> some View {
        let isActive = state.activeMovementMode == mode
        let target: MovementMode? = isActive ? nil : mode
        return Button {
            if hasActiveSession && target != state.activeMovementMode {
                pendingSwitch = PendingSwitch(target: target)
            } else {
                state.activeMovementMode = target
            }
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
        .disabled(state.selectedUDID == nil || state.isVirtualMapSelected || blockedByRoute)
        .help(state.selectedUDID == nil
              ? LocalizedStringKey("Select a device first.")
              : (state.isVirtualMapSelected
                 ? LocalizedStringKey("Switch to a connected iPhone to use movement modes.")
                 : (blockedByRoute
                    ? LocalizedStringKey("Stop the active route before switching to Multi-stop mode.")
                    : title)))
    }
}
