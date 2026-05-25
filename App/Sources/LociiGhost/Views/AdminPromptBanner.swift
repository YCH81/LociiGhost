import SwiftUI

/// Floating banner shown over the map when the daemon doesn't have
/// root privileges. Clicking the button triggers macOS's native admin
/// authentication dialog (Touch ID / password) — the user never opens
/// a terminal. After a successful authenticate the banner disappears
/// on its own as the app re-attaches to the freshly-spawned root
/// daemon.
struct AdminPromptBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if shouldShow {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Admin authentication needed")
                        .font(.caption.weight(.semibold))
                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await state.requestAdminElevation() }
                } label: {
                    if state.isElevating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Authenticating…")
                        }
                    } else {
                        Text("Authenticate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(state.isElevating)
            }
            .padding(10)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
            )
            .frame(maxWidth: 540)
        }
    }

    /// Show whenever we know the daemon is unprivileged, OR a previous
    /// Connect attempt blew up at the tunnel step. nil daemonIsRoot
    /// (haven't queried yet / daemon down) doesn't trigger the banner
    /// so we don't flash it during startup.
    ///
    /// (v1.11.2 round 4 perf revert: the `.failed`-status branch was
    /// removed; the AppState auto-elevate trigger still fires the
    /// system prompt automatically on Tahoe, and the DaemonStatusPill
    /// is the visible recovery affordance for non-auto cases.)
    private var shouldShow: Bool {
        state.needsAdminElevation || state.daemonIsRoot == false
    }

    private var detailText: String {
        if state.daemonIsRoot == false {
            return "Connecting an iPhone (iOS 17+) needs admin privileges to set up the network tunnel. Click to authenticate; you only do this once per Mac restart."
        }
        if state.needsAdminElevation {
            return "Daemon needs to restart to pick up updated code. Click to re-authenticate."
        }
        return "Click to authenticate."
    }
}
