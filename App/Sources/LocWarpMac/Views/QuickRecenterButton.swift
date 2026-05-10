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

    var body: some View {
        Button {
            recenter()
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: .circle)
                .overlay(
                    Circle().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .disabled(targetCoordinate() == nil)
    }

    // MARK: -

    private func recenter() {
        guard let target = targetCoordinate() else { return }
        state.pendingMapFly = MapFlyRequest(coordinate: target, spanMeters: 2_000)
    }

    /// Resolves to whichever coordinate the button should fly to right now.
    private func targetCoordinate() -> Coordinate? {
        if let sim = state.simulatedLocation {
            return sim
        }
        if let mac = state.macLocation.coordinate {
            return Coordinate(lat: mac.latitude, lng: mac.longitude)
        }
        return nil
    }

    private var glyph: String {
        if state.simulatedLocation != nil {
            return "iphone.gen3.circle.fill"
        }
        return "location.fill"
    }

    private var tint: Color {
        if state.simulatedLocation != nil {
            return .green
        }
        return .accentColor
    }

    private var helpText: String {
        if state.simulatedLocation != nil {
            return "Recenter on iPhone's simulated position"
        }
        if state.macLocation.coordinate != nil {
            return "Recenter on Mac's location (≈ iPhone real GPS)"
        }
        return "No location known yet"
    }
}
