import SwiftUI

/// Floating button that flies the map back to "where the iPhone is".
///
/// Logic:
/// 1. If we're actively simulating, "where the iPhone is" is the spoofed
///    coordinate — that's what the phone itself thinks. Fly there in
///    green-pin mode.
/// 2. Otherwise, the iPhone is on its real GPS, which we can't read over
///    DVT. Fall back to the Mac's CoreLocation as the closest available
///    proxy. Fly there in blue-puck mode.
/// 3. If neither is known yet, the button stays disabled with a hint.
struct QuickRecenterButton: View {
    @Environment(AppState.self) private var state
    @State private var hovering = false

    var body: some View {
        Button {
            recenter()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: .circle)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                hovering
                                    ? Color.lociSage.opacity(0.7)
                                    : Color.secondary.opacity(0.2),
                                lineWidth: hovering ? 1.5 : 0.5,
                            ),
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 4, y: 1)
                Text("Recenter",
                     comment: "Floating-button label next to the recenter disc on the map")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5),
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 4, y: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .disabled(targetCoordinate() == nil)
    }

    // MARK: -

    private func recenter() {
        guard let target = targetCoordinate() else { return }
        state.pendingMapFly = MapFlyRequest(coordinate: target, spanMeters: 2_000)
    }

    /// Resolves to whichever coordinate the button should fly to right now.
    /// Uses `currentMapFocus` so browse-mode click → recenter goes to
    /// the browse pin, real-iPhone mode → recenter goes to simulated GPS.
    private func targetCoordinate() -> Coordinate? {
        if let focus = state.currentMapFocus {
            return focus
        }
        if let mac = state.macLocation.coordinate {
            return Coordinate(lat: mac.latitude, lng: mac.longitude)
        }
        return nil
    }

    private var glyph: String {
        if state.currentMapFocus != nil {
            return "iphone.gen3.circle.fill"
        }
        return "location.fill"
    }

    private var tint: Color {
        if state.currentMapFocus != nil {
            return .green
        }
        return .accentColor
    }

    private var helpText: String {
        if state.currentMapFocus != nil {
            return state.isVirtualMapSelected
                ? "Recenter on the browse pin"
                : "Recenter on iPhone's simulated position"
        }
        if state.macLocation.coordinate != nil {
            return "Recenter on Mac's location (≈ iPhone real GPS)"
        }
        return "No location known yet"
    }
}
