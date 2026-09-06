import SwiftUI
import AppKit
import LociiGhostCore

/// Header-bar pill that turns the docked iPhone-Mirroring panel on
/// and off, plus the popover that explains what's going on when it
/// can't (no Accessibility grant, no window yet, doesn't fit).
///
/// Visual contract matches `s2GridButton` in `AppHeaderBar`: capsule,
/// tinted + filled when active, neutral grey when off.
struct MirrorDockButton: View {
    @Environment(AppState.self) private var state
    @State private var showingPopover = false

    private var dock: MirrorDock { state.mirrorDock }

    var body: some View {
        // A Mac that has no iPhone Mirroring.app gets no button at
        // all — better than a permanently disabled control the user
        // has to go read a tooltip to understand.
        if dock.status != .unsupported {
            button
        }
    }

    private var isOn: Bool { dock.status == .docked || dock.status == .waitingForWindow }

    private var accent: Color {
        switch dock.status {
        case .docked:          return .accentColor
        case .waitingForWindow: return .orange
        case .needsPermission, .failed: return .orange
        default:               return .secondary
        }
    }

    private var button: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Label {
                Text("Mirror",
                     comment: "Header bar — button label for the docked iPhone Mirroring panel")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
            } icon: {
                Image(systemName: isOn
                      ? "iphone.gen3.badge.play"
                      : "iphone.gen3")
                    .font(.caption)
                    .foregroundStyle(isOn ? accent : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isOn
                    ? AnyShapeStyle(accent.opacity(0.15))
                    : AnyShapeStyle(Color.secondary.opacity(0.08)),
                in: .capsule,
            )
            .overlay(
                Capsule().strokeBorder(
                    isOn ? accent.opacity(0.45) : Color.secondary.opacity(0.25),
                    lineWidth: 0.5,
                ),
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 12)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            MirrorDockPopover()
                .environment(state)
        }
        .help(Text("Dock your iPhone's screen next to LociiGhost — play on the Mac while the fake location runs.",
                   comment: "Tooltip on the mirror-dock header button"))
        // Coming back from System Settings is the one moment the
        // grant can change under us, and macOS gives us no
        // notification for it. Re-checking when the popover opens
        // costs one cheap syscall and saves the user a restart.
        .onChange(of: showingPopover) { _, isOpen in
            if isOpen { dock.recheckPermission() }
        }
    }
}

// MARK: - Popover

private struct MirrorDockPopover: View {
    @Environment(AppState.self) private var state

    private var dock: MirrorDock { state.mirrorDock }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3.badge.play")
                    .foregroundStyle(Color.accentColor)
                Text("iPhone screen",
                     comment: "Mirror dock popover — title")
                    .font(.headline)
            }

            Text("Uses macOS's built-in iPhone Mirroring and glues its window to the side of LociiGhost. Taps go straight to Apple's mirroring — LociiGhost never sits in the input path, so there's no added lag.",
                 comment: "Mirror dock popover — what the feature does")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            switch dock.status {
            case .needsPermission: permissionBody
            case .failed(let message): failedBody(message)
            default: controlsBody
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // ── Normal controls ───────────────────────────────────────────

    @ViewBuilder
    private var controlsBody: some View {
        Toggle(isOn: Binding(
            get: { dock.status == .docked || dock.status == .waitingForWindow },
            set: { on in
                if on { dock.enable() } else { dock.disable() }
            },
        )) {
            Text("Dock iPhone screen",
                 comment: "Mirror dock popover — main on/off toggle")
                .font(.callout)
        }
        .toggleStyle(.switch)

        Picker(selection: Binding(
            get: { dock.edge },
            set: { dock.edge = $0 },
        )) {
            Text("Right", comment: "Mirror dock popover — dock the phone to the right of the window")
                .tag(MirrorDockEdge.right)
            Text("Left", comment: "Mirror dock popover — dock the phone to the left of the window")
                .tag(MirrorDockEdge.left)
        } label: {
            Text("Side", comment: "Mirror dock popover — which edge to dock on")
                .font(.callout)
        }
        .pickerStyle(.segmented)

        statusLine

        if dock.status == .docked, !dock.fitsOnScreen {
            calloutRow(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                text: Text("This window plus the phone is wider than the display, so they overlap. Make the LociiGhost window narrower, or pick a smaller size in iPhone Mirroring's View menu.",
                           comment: "Mirror dock popover — warning when the pair is wider than the screen"),
            )
        }

        if dock.mirrorSizeIsSettable == false {
            calloutRow(
                icon: "info.circle.fill",
                tint: .secondary,
                text: Text("iPhone Mirroring keeps its own window size — change it from that app's View menu (Actual Size / Larger / Smaller). LociiGhost lays out around whatever it picks.",
                           comment: "Mirror dock popover — note when the mirror window refuses AXSize writes"),
            )
        }

        if !dock.diagnostics.isEmpty {
            Text(verbatim: dock.diagnostics)
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if dock.status == .docked || dock.status == .waitingForWindow {
            Button(role: .destructive) {
                dock.quitMirrorApp()
            } label: {
                Text("Quit iPhone Mirroring",
                     comment: "Mirror dock popover — fully quit the mirroring app")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            switch dock.status {
            case .docked:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Docked", comment: "Mirror dock popover — status: attached and following")
            case .waitingForWindow:
                ProgressView().controlSize(.small)
                Text("Waiting for iPhone Mirroring — unlock your iPhone if it's asking.",
                     comment: "Mirror dock popover — status: launched but no window yet")
            default:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("Off", comment: "Mirror dock popover — status: not docked")
            }
            Spacer(minLength: 0)
            if dock.mirrorSize.width > 1 {
                Text(verbatim: "\(Int(dock.mirrorSize.width))×\(Int(dock.mirrorSize.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // ── Permission ────────────────────────────────────────────────

    @ViewBuilder
    private var permissionBody: some View {
        calloutRow(
            icon: "lock.circle.fill",
            tint: .orange,
            text: Text("LociiGhost needs Accessibility permission to position the mirroring window. Nothing else uses it.",
                       comment: "Mirror dock popover — why the Accessibility grant is needed"),
        )
        HStack(spacing: 8) {
            Button {
                dock.openAccessibilitySettings()
            } label: {
                Text("Open Privacy Settings",
                     comment: "Mirror dock popover — jump to the Accessibility pane")
            }
            Button {
                dock.enable()
            } label: {
                Text("Try again",
                     comment: "Mirror dock popover — re-check the Accessibility grant")
            }
        }
        .controlSize(.small)
        Text("If LociiGhost is already listed there, switch it off and on again — the permission is tied to the exact app binary, so a fresh build needs re-approving.",
             comment: "Mirror dock popover — the stale-TCC-entry gotcha")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func failedBody(_ message: String) -> some View {
        calloutRow(
            icon: "xmark.octagon.fill",
            tint: .red,
            text: Text(verbatim: message),
        )
        Button {
            dock.enable()
        } label: {
            Text("Try again", comment: "Mirror dock popover — retry after a failure")
        }
        .controlSize(.small)
    }

    // ── Shared bits ───────────────────────────────────────────────

    private func calloutRow(icon: String, tint: Color, text: Text) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            text
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
