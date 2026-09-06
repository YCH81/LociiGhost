import SwiftUI
import CoreLocation

/// Why "Snap to real location" did nothing, and how to fix it.
///
/// A toast was the wrong shape for this. Denial is not a transient
/// failure: macOS only shows its permission prompt once, so an app
/// that has been refused can never ask again — the user has to walk
/// into System Settings themselves. That deserves the steps and a
/// button that opens the right pane, not a line of red text that
/// disappears after ten seconds.
struct LocationPermissionSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// Deep link to Privacy & Security → Location Services.
    private static let locationPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")

    private var isDenied: Bool {
        switch state.macLocation.status {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Read straight off `LocationProxyService`, which is `@Observable`
    /// and updates from CoreLocation's authorization callback. That is
    /// the point of putting the state here rather than in a one-shot
    /// message: the user can leave this sheet open, flip the switch in
    /// System Settings, and watch this line turn green without having
    /// to guess whether it took.
    private var granted: Bool {
        switch state.macLocation.status {
        case .authorized, .authorizedAlways: return true
        default: return false
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: granted
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill")
                .font(.title3)
            Text(granted
                 ? LocalizedStringKey("Location access is on")
                 : LocalizedStringKey("Location access is not on yet"))
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(granted ? Color.green : Color.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((granted ? Color.green : Color.orange).opacity(0.12),
                    in: .rect(cornerRadius: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "location.slash")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Can't read this Mac's location",
                     comment: "Location permission sheet — title")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            statusBanner

            Text("Snap to real location moves the iPhone to wherever this Mac is, so it needs macOS location access. LociiGhost never sends that position anywhere — it goes straight to the connected iPhone.",
                 comment: "Location permission sheet — what the permission is for")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                Text("Nothing more to do here — close this and press Snap to real location again. If it still does nothing, the Mac may not have a position fix yet; give it a moment near a window.",
                     comment: "Location permission sheet — shown once access has been granted")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isDenied {
                Text("Access is currently turned off. macOS only asks once, so the app can't bring the prompt back — the switch has to be flipped in System Settings.",
                     comment: "Location permission sheet — explains why no prompt appears")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No position has arrived yet. If the prompt never appeared, the switch may be off in System Settings; otherwise give it a moment near a window and try again.",
                     comment: "Location permission sheet — no fix yet, permission may still be undecided")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !granted {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Open System Settings → Privacy & Security → Location Services.")
                    step(2, "Turn Location Services on if it is off.")
                    step(3, "Find LociiGhost in the list and switch it on.")
                    step(4, "Come back and press Snap to real location again.")
                }
                .padding(.vertical, 2)
            }
            }

            HStack {
                if let url = Self.locationPaneURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open System Settings", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .help(LocalizedStringKey("Opens Privacy & Security → Location Services"))
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
