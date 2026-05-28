import SwiftUI
import AppKit

/// "Status Bar A" — the strip directly above the map, between
/// AppHeaderBar (version + lang + Phone Control) and the map itself.
///
/// Layout:
///
///   ┌──────────────────────────────────────────────────────────────────┐
///   │ [還原] [中斷連線] [重新整理] [退出] … 🇹🇼 台灣 ☁ 26°C  121.56,…  │
///   │                                       Mac time   |  GPS time     │
///   └──────────────────────────────────────────────────────────────────┘
///
/// The right-side info chips and left-side action buttons are sized
/// to match the AppHeaderBar's Phone Control button so the whole top
/// strip reads as one cohesive control surface. Each chip carries a
/// hover highlight so users know they're interactive (the coords
/// chip has a copy button; the others are read-only but the
/// highlight still helps users learn the layout).
struct TopStatusBar: View {
    @Environment(AppState.self) private var state
    /// SwiftUI's locale, set by `LociiGhostApp` from the
    /// AppLanguage picker (`.environment(\.locale, …)`). We pass
    /// this into `CountryDisplay.displayName` so the country chip
    /// re-renders in the picker's language on every toggle.
    @Environment(\.locale) private var locale

    var body: some View {
        // v1.11.2 round 16 perf: the 1 Hz clock timer + nowTick
        // @State used to live here on the outer body, which meant
        // every tick re-evaluated the whole TopStatusBar (5 left
        // buttons + 5 right chips + their AppKit layout pass) just
        // to update the times chip's text. Sample(1) caught ~40% of
        // main-thread time stuck inside NSView._layoutSubtreeWithOldSize
        // recursion on idle as a direct result. The timer + state
        // now lives inside `TimesChip` itself (see file footer); the
        // outer TopStatusBar body re-evaluates only on event-driven
        // state changes (selection / weather refresh / etc).
        HStack(spacing: 12) {
            leftButtons
            Spacer(minLength: 12)
            rightInfo
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // minHeight: defensive floor so NSViewRepresentable height-
        // competition in the parent VStack never compresses this bar
        // to zero. Combined with .layoutPriority(1) on this view in
        // MainView, the bar always claims its natural height first.
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Left: 還原 / 中斷連線 / 重新整理 / 退出

    /// Sized + styled to match AppHeaderBar's Phone Control button so
    /// the whole top strip reads as one consistent control row.
    /// `.bordered` style means macOS gives us hover feedback for free.
    @ViewBuilder
    private var leftButtons: some View {
        HStack(spacing: 6) {
            // Exit-sync button — only visible when BOTH a phone
            // session is active AND sync mode is on (i.e. the
            // user opted into simultaneous control earlier).
            // Tap → setSyncMode(false), which restores the
            // lockout overlay so the Mac is no longer driving
            // alongside the phone. We place it before Restore so
            // the user reaches for the "go back to safer mode"
            // option first.
            if state.phoneSessionActive && state.syncModeActive {
                statusBarButton(
                    titleKey: "Exit sync",
                    fallback: "Exit sync",
                    symbol: "arrow.left.arrow.right.circle.fill",
                    tint: .orange,
                    disabled: false,
                    helpKey: "Stop driving simultaneously with the phone — locks the Mac side back to phone control",
                ) {
                    Task { await state.setSyncMode(false) }
                }
            }

            // v1.11.2 round 13: Snap-to-real re-introduced with a
            // perf-safe contract — `disabled` only reads
            // `activeDevice?.connected` (which changes on connect /
            // disconnect events, not on a CoreLocation tick). The
            // round-1 attempt also read `state.macLocation.coordinate`
            // here which is a high-frequency publisher, redrawing
            // the entire TopStatusBar on every fix update. Now the
            // Mac coord is fetched LAZILY at click time inside
            // `snapToReal(udid:)`; if it comes back nil the helper
            // surfaces a toast instead of disabling the button.
            statusBarButton(
                titleKey: "Snap to real",
                fallback: "Snap to real location",
                symbol: "figure.walk.arrival",
                tint: .green,
                disabled: activeDevice?.connected != true,
                helpKey: "Teleport the simulated iPhone to your Mac's current real location — simulation stays active",
            ) {
                guard let udid = activeDevice?.udid else { return }
                Task { await snapToReal(udid: udid) }
            }

            statusBarButton(
                titleKey: "Restore",
                fallback: "Restore Real GPS",
                symbol: "arrow.counterclockwise",
                tint: .accentColor,
                disabled: activeDevice?.connected != true,
                helpKey: "Stop simulating and let the device report its real location",
            ) {
                guard let udid = activeDevice?.udid else { return }
                Task { await state.restore(udid: udid) }
            }

            statusBarButton(
                titleKey: "Disconnect",
                fallback: "Disconnect",
                symbol: "iphone.slash",
                tint: .red,
                disabled: activeDevice?.connected != true,
                helpKey: nil,
            ) {
                guard let udid = activeDevice?.udid else { return }
                Task { await state.disconnect(udid: udid) }
            }

            statusBarButton(
                titleKey: "Refresh",
                fallback: "Refresh",
                symbol: "arrow.clockwise",
                tint: .accentColor,
                disabled: false,
                helpKey: "Re-scan for connected devices",
            ) {
                Task { await state.refreshDevices() }
            }

            Divider().frame(height: 22)

            statusBarButton(
                titleKey: "Quit",
                fallback: "Quit",
                symbol: "power",
                tint: .secondary,
                disabled: false,
                helpKey: "Quit LociiGhost. The privileged daemon stays running so the next launch doesn't need the password.",
            ) {
                state.quitApp()
            }
        }
    }

    /// One row of left-side buttons. Centralised so all four match in
    /// padding, font, hover behaviour. Bordered style keeps the
    /// macOS-native click feedback; we add `hoverHighlight` on top
    /// for a stronger background tint than the system gives.
    @ViewBuilder
    private func statusBarButton(
        titleKey: LocalizedStringKey,
        fallback: String,
        symbol: String,
        tint: Color,
        disabled: Bool,
        helpKey: LocalizedStringKey?,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(titleKey)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(.regular)
        .disabled(disabled)
        .hoverHighlight(cornerRadius: 6)
        .help(helpKey ?? LocalizedStringKey(fallback))
    }

    // MARK: - Right: country / weather / coords / two clocks

    /// Each info element is wrapped in `infoChip` so they all share
    /// padding, hover background, and font sizing — matches the
    /// visual weight of Phone Control on the row above.
    @ViewBuilder
    private var rightInfo: some View {
        HStack(spacing: 8) {
            countryChip
            weatherChip
            coordsChip
            timesChip
        }
        .font(.callout.monospacedDigit())
    }

    // ── chip helper ──────────────────────────────────────────────

    /// One "info pill" with hover highlight. Read-only chips (weather,
    /// country) use this directly; the coords chip has its own
    /// version with an embedded copy button.
    @ViewBuilder
    private func infoChip<Content: View>(
        @ViewBuilder content: () -> Content,
        help: LocalizedStringKey,
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5),
            )
            .hoverHighlight(cornerRadius: 6, changesCursor: false)
            .help(help)
    }

    // ── country chip ─────────────────────────────────────────────

    /// Flag + short Chinese country name for the simulated puck.
    /// Falls back to a placeholder when no geo-context is loaded
    /// (no simulation OR the geocode hasn't returned yet).
    private var countryChip: some View {
        infoChip(
            content: {
                HStack(spacing: 4) {
                    Text(CountryDisplay.flagEmoji(
                        isoCode: state.simulatedGeoContext?.isoCountryCode,
                    ))
                        .font(.title3)
                    Text(CountryDisplay.displayName(
                        isoCode: state.simulatedGeoContext?.isoCountryCode,
                        locale: locale,
                        geocoderFallback: state.simulatedGeoContext?.localisedCountryName,
                    ))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            },
            help: LocalizedStringKey("Country of the simulated location"),
        )
    }

    // ── weather chip ─────────────────────────────────────────────

    private var weatherChip: some View {
        infoChip(
            content: {
                if let w = state.currentWeather {
                    HStack(spacing: 5) {
                        Image(systemName: w.condition.symbol)
                            .foregroundStyle(weatherColor(w.condition))
                        Text(String(format: "%.0f°C", w.temperatureC))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.tertiary)
                        Text("—")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            },
            help: LocalizedStringKey("Weather at the simulated location"),
        )
    }

    private func weatherColor(_ c: WeatherService.Condition) -> Color {
        switch c {
        case .sunny:  return .orange
        case .cloudy: return .secondary
        case .rain:   return .blue
        case .snow:   return .cyan
        case .hail:   return .purple
        }
    }

    // ── coords chip ──────────────────────────────────────────────

    /// v1.11.2 round 18: CoordsChip lives in its own struct so its
    /// dependency on `state.macLocation.coordinate` (a 1 Hz
    /// CoreLocation publisher) only invalidates the chip itself.
    /// Before, this read was part of TopStatusBar's outer body,
    /// so every CoreLocation tick re-evaluated the whole status
    /// bar — visible as drag-stutter when a device was connected.
    private var coordsChip: some View {
        CoordsChip()
    }

    // ── times chip ───────────────────────────────────────────────

    /// v1.11.2 round 16: TimesChip lives in its own struct (file
    /// bottom) so its 1 Hz clock timer only invalidates the chip
    /// itself, not the whole TopStatusBar tree.
    private var timesChip: some View {
        TimesChip()
    }

    // MARK: - Helpers

    private var activeDevice: DeviceVM? {
        guard let udid = state.selectedUDID else { return nil }
        return state.devices.first(where: { $0.udid == udid })
    }

    /// v1.11.2 round 13: Snap-to-real action. Mac coord is fetched
    /// LAZILY here (not in the disabled-state check), so a busy
    /// CoreLocation publisher doesn't re-render the entire
    /// TopStatusBar on every fix tick. Tries a fresh fix first
    /// (~2s for accuracy) and falls back to the cached coord;
    /// when neither is available we surface a toast asking the
    /// user to enable Location in System Settings.
    ///
    /// v1.11.2 bugfix: also pan the map to the destination — the
    /// applyPositionEvent map-follow loop only fires while an
    /// active "moving" mode (joystick / random walk / nav) is
    /// running, so a pure teleport like this one would otherwise
    /// move the simulated pin offscreen with no camera change.
    /// Mirrors the search-bar Teleport flow.
    private func snapToReal(udid: String) async {
        // Stop ALL active sessions before teleporting so the iPhone
        // lands at the real location and stays still — no lingering
        // route / random walk / joystick continuing to push the pin.
        if state.navigationActive  { await state.stopNavigation(udid: udid) }
        if state.randomWalkActive  { await state.stopRandomWalk(udid: udid) }
        if state.joystickActive    { await state.stopJoystick(udid: udid) }
        // Also clear the movement-mode panel so the sidebar is idle.
        state.activeMovementMode = nil

        var coord = await state.macLocation.fetchFreshFix(timeout: 2.0)
        if coord == nil { coord = state.macLocation.coordinate }
        guard let c = coord else {
            state.lastError = String(
                localized: "Mac location unavailable — open System Settings → Privacy → Location and allow LociiGhost.",
                comment: "Toast when Snap-to-real fires with no Mac CoreLocation fix yet",
            )
            return
        }
        state.pendingMapFly = MapFlyRequest(
            coordinate: Coordinate(lat: c.latitude, lng: c.longitude),
            spanMeters: 2_000,
        )
        await state.teleport(udid: udid, lat: c.latitude, lng: c.longitude)
    }
}

/// v1.11.2 round 18 perf: extracted CoordsChip into its own view so
/// its `state.macLocation.coordinate` and `state.currentMapFocus`
/// dependencies only invalidate this chip. Each CoreLocation tick
/// otherwise redrew the whole TopStatusBar tree, contending with
/// MapKit's per-frame render on a connected device.
private struct CoordsChip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "scope")
                .foregroundStyle(.tint)
            if let c = displayedCoord {
                Text(String(format: "%.5f, %.5f", c.lat, c.lng))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Button {
                    copyCoord(c)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .padding(2)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .hoverHighlight(cornerRadius: 4)
                .help(LocalizedStringKey("Copy coordinates"))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5),
        )
        .hoverHighlight(cornerRadius: 6, changesCursor: false)
        .help(LocalizedStringKey("Coordinates of the simulated location"))
    }

    /// Falls back to Mac proxy when no simulated coord is active.
    private var displayedCoord: Coordinate? {
        if let s = state.currentMapFocus { return s }
        if let m = state.macLocation.coordinate {
            return Coordinate(lat: m.latitude, lng: m.longitude)
        }
        return nil
    }

    private func copyCoord(_ c: Coordinate) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(String(format: "%.6f, %.6f", c.lat, c.lng), forType: .string)
    }
}

/// v1.11.2 round 16 perf: extracted clock-chip into its own view so
/// the 1 Hz timer's @State update only invalidates this chip — not
/// the entire TopStatusBar (5 left buttons + 5 right chips). Before
/// this, sample(1) caught ~40% of main-thread time in
/// NSView._layoutSubtreeWithOldSize recursion at idle, because each
/// timer tick redrew the whole status bar and AppKit revisited every
/// nested view's layout.
///
/// Two stacked timestamps. Top is the Mac's wall clock; bottom is
/// the wall clock at the simulated location's timezone. When the
/// two timezones match (or we haven't yet learned the GPS tz) we
/// hide the bottom row to save horizontal space.
private struct TimesChip: View {
    @Environment(AppState.self) private var state
    @State private var nowTick: Date = .now
    /// Stored so we only write `nowTick` when the visible string would
    /// actually change. The format below stops at minute precision, so
    /// 59 of every 60 timer fires emit the same string. Each redundant
    /// nowTick write triggers a full SwiftUI body re-eval and (worse)
    /// an AppKit `-[NSWindow layoutIfNeeded]` cascade that walks the
    /// entire detail-pane tree (BottomBar pickers, MapContainer wrap,
    /// etc.) — the 5-second pan-sample profile attributed ~26 % of
    /// main-thread time to this cascade during "iPhone connected"
    /// idle pan. Pure idle was smoother because the secondary
    /// "iPhone TZ" row didn't render, halving the cost.
    @State private var lastMinuteEpoch: Int = Int(Date().timeIntervalSince1970 / 60)
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let tz = state.simulatedTimeZone
        let showRemote = tz != nil && tz != TimeZone.current
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "macbook")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(formattedNow(in: TimeZone.current))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .monospacedDigit()
            }
            if showRemote, let tz {
                HStack(spacing: 5) {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(formattedNow(in: tz))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .monospacedDigit()
                    Text(tz.abbreviation() ?? tz.identifier)
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5),
        )
        .hoverHighlight(cornerRadius: 6, changesCursor: false)
        .help(LocalizedStringKey("Mac time / Time at the simulated location"))
        .onReceive(clockTimer) { tick in
            // Throttle to minute boundaries — that's the smallest unit
            // the rendered string cares about. Saves ~59/60 of the
            // body re-evals and (more importantly) the AppKit layout
            // cascades they cause.
            let minute = Int(tick.timeIntervalSince1970 / 60)
            if minute != lastMinuteEpoch {
                lastMinuteEpoch = minute
                nowTick = tick
            }
        }
    }

    /// Static formatter cache — DateFormatter creation is heavy, and
    /// the per-body-eval `let f = DateFormatter()` ran multiple times
    /// per second before the minute-throttle landed. Keyed by tz id so
    /// repeated lookups for the same zone are O(1).
    private static let formatterCache = NSCache<NSString, DateFormatter>()
    private static func formatter(for tz: TimeZone) -> DateFormatter {
        let key = tz.identifier as NSString
        if let cached = formatterCache.object(forKey: key) {
            return cached
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        f.timeZone = tz
        formatterCache.setObject(f, forKey: key)
        return f
    }

    private func formattedNow(in tz: TimeZone) -> String {
        Self.formatter(for: tz).string(from: nowTick)
    }
}
