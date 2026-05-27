import SwiftUI

/// Floating map-layer chooser pinned to the top-RIGHT of the map,
/// directly under `QuickRecenterButton`. Visual contract matches
/// QuickRecenterButton exactly:
///
///   * 30 × 30 round disc on the left, frosted material, hairline
///     stroke that thickens + flips to accent on hover
///   * separate frosted-capsule label on the right with the
///     button's function name ("Map Layer" / "地圖圖層")
///   * both pieces sit inside the same `Menu`, so clicking either
///     opens the layer picker
struct MapLayerPicker: View {
    @Environment(AppState.self) private var state
    @State private var hovering = false

    var body: some View {
        @Bindable var state = state
        Menu {
            ForEach(MapTileLayer.allCases) { layer in
                Button {
                    state.mapTileLayer = layer
                } label: {
                    Label {
                        HStack {
                            Text(layer.displayName)
                            if state.mapTileLayer == layer {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    } icon: {
                        Image(systemName: layer.symbol)
                    }
                }
            }
            Divider()
            // Bookmark-pin overlay sits ABOVE the base layer; toggling
            // doesn't change the picked tile source. Treated as a layer
            // because it's a visible-on-the-map setting, and a single
            // overflow menu is friendlier than scattering toggles across
            // the floating-button row.
            Button {
                state.showBookmarksOnMap.toggle()
            } label: {
                Label {
                    HStack {
                        Text("Show bookmarks on map",
                             comment: "Map-layer menu — toggle bookmark pins overlay")
                        if state.showBookmarksOnMap {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                } icon: {
                    Image(systemName: "bookmark")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
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
                Text("Map Layer",
                     comment: "Floating-button label next to the map-layer disc on the map")
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(Text("Map Layer · \(currentLayerName)",
                   comment: "Tooltip on the floating map-layer button — shows current layer"))
    }

    /// Compose the tooltip's "current layer" suffix as a String so
    /// the `LocalizedStringKey`-style interpolation works without
    /// double-localising the layer name.
    private var currentLayerName: String {
        switch state.mapTileLayer {
        case .appleStandard:
            return String(localized: "Apple Maps")
        case .appleSatellite:
            return String(localized: "Apple Satellite")
        case .openStreetMap:
            return String(localized: "OpenStreetMap")
        case .cartoVoyager:
            return String(localized: "Carto Voyager")
        case .esriSatellite:
            return String(localized: "ESRI Satellite")
        }
    }
}
