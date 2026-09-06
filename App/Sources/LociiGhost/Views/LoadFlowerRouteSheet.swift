import SwiftUI
import SwiftData
import LociiGhostCore

/// Pick a saved route and orbit its points instead of driving through
/// them. Routes and flower waypoints are both just ordered coordinate
/// lists, so a track worth recording is usually a set of places worth
/// circling — without this the user has to re-click a route they
/// already saved.
///
/// Deliberately not a two-action confirm like `LoadStopPresetSheet`:
/// there is no "teleport to first" question to answer, because
/// `startFlower` puts the iPhone on the first ring itself.
struct LoadFlowerRouteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Route.createdAt, order: .reverse)])
    private var routes: [Route]

    /// Above this, orbiting every point is almost certainly not what
    /// the user meant — a recorded GPX track can carry hundreds. We
    /// still allow it (their route, their call) but say so, rather
    /// than silently thinning the list and producing a run that does
    /// not match the route they picked.
    private static let busyRouteThreshold = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "camera.macro")
                    .foregroundStyle(.tint)
                    .font(.title2)
                Text("Orbit a saved route",
                     comment: "LoadFlowerRouteSheet — title")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            if routes.isEmpty {
                Text("No saved routes yet. Import a GPX track or save the staged points as a route first.",
                     comment: "LoadFlowerRouteSheet — empty state")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Every point becomes a ring centre. The current waypoints are replaced.",
                     comment: "LoadFlowerRouteSheet — body explaining what picking a route does")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(routes) { route in
                            routeRow(route)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func routeRow(_ route: Route) -> some View {
        Button {
            state.loadRouteAsFlowerWaypoints(route)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: route.iconSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(route.name)
                        .font(.callout)
                    HStack(spacing: 4) {
                        Text(String(
                            format: String(localized: "%lld points",
                                           comment: "LoadFlowerRouteSheet — point count for a route row"),
                            route.pointCount))
                            .font(.caption2)
                            .foregroundStyle(route.pointCount > Self.busyRouteThreshold
                                             ? Color.orange : Color.secondary)
                        if route.pointCount > Self.busyRouteThreshold {
                            Text("— that is a lot of rings",
                                 comment: "LoadFlowerRouteSheet — caution next to a very long route")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
