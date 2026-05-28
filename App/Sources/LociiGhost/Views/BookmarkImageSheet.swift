import SwiftUI

/// Modal sheet that renders a bookmark's `imageURL` inline so the user
/// can preview the photo associated with a saved location. Loading is
/// delegated to SwiftUI's `AsyncImage` — the framework's URLCache
/// handles same-session caching, so revisiting a bookmark within one
/// app session is effectively instant after the first fetch.
///
/// Nothing is persisted to disk: the network footprint per open is
/// one HTTP GET. If the request fails (offline, 404, etc.) the sheet
/// shows a fallback message with a retry button rather than blowing
/// the entire flow up.
///
/// The "Teleport here" button mirrors the row tap behaviour so the
/// user can preview the photo first, then jump to that GPS point
/// without dismissing the sheet manually first.
struct BookmarkImageSheet: View {
    let bookmark: Bookmark
    /// Caller-provided dismiss closure. We can't rely on
    /// `@Environment(\.dismiss)` because v1.13's presentation moved
    /// from a `.sheet` modifier (which provides .dismiss) to a custom
    /// overlay rooted in MainView (which doesn't). The overlay needs
    /// to clear `state.mapPreviewingBookmark`; this closure lets the
    /// presenter decide how.
    let onDismiss: () -> Void
    @Environment(AppState.self) private var state
    /// Bumped to force `AsyncImage` to redo the network fetch when
    /// the user taps Retry on the error state.
    @State private var retryToken: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            imageArea
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 640, maxWidth: 900,
               minHeight: 380, idealHeight: 560, maxHeight: 900)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: bookmark.iconSymbol)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(String(format: "%.5f, %.5f", bookmark.lat, bookmark.lng))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help(Text("Close",
                       comment: "Tooltip on bookmark image sheet close button"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Image area

    @ViewBuilder
    private var imageArea: some View {
        if let raw = bookmark.imageURL, let url = URL(string: raw) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case .empty:
                    loadingView
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.04))
                case .failure:
                    failureView
                @unknown default:
                    loadingView
                }
            }
            .id(retryToken)
        } else {
            failureView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("Loading photo…",
                 comment: "Spinner label while fetching a bookmark's remote image")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.04))
    }

    private var failureView: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Couldn't load the photo.",
                 comment: "Error message when a bookmark's remote image fails to load")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                retryToken &+= 1
            } label: {
                Label {
                    Text("Retry",
                         comment: "Button to retry loading a bookmark's image")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.04))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                goToBookmark()
            } label: {
                Label {
                    Text("Show on map",
                         comment: "Button in bookmark image sheet to fly the map to the saved location")
                } icon: {
                    Image(systemName: "scope")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Fly the map to the bookmark and, when a real connected device is
    /// the active selection, also teleport it. Browse-only (virtual
    /// map) and "no device picked" both succeed at the fly step so the
    /// user can preview locations without owning a phone session.
    private func goToBookmark() {
        state.pendingMapFly = MapFlyRequest(
            coordinate: Coordinate(lat: bookmark.lat, lng: bookmark.lng),
            spanMeters: 2_000,
        )
        if let udid = state.selectedUDID,
           udid != AppState.virtualMapUDID,
           state.devices.first(where: { $0.udid == udid })?.connected == true {
            Task {
                await state.teleport(udid: udid,
                                     lat: bookmark.lat, lng: bookmark.lng)
            }
        }
        onDismiss()
    }
}
