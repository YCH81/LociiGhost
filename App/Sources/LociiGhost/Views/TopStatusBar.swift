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
    @State private var nowTick: Date = .now
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            leftButtons
            Spacer(minLength: 12)
            rightInfo
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
        .onReceive(clockTimer) { nowTick = $0 }
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
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.tertiary)
                        Text("—")
                            .foregroundStyle(.tertiary)
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

    /// Coords pill with embedded copy button. Built bespoke (instead
    /// of calling `infoChip`) because the copy button needs to live
    /// inside the same border as the coords text — splitting it out
    /// into a separate chip makes the row feel cluttered.
    private var coordsChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "scope")
                .foregroundStyle(.tint)
            if let c = displayedCoord {
                Text(String(format: "%.5f, %.5f", c.lat, c.lng))
                    .textSelection(.enabled)
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

    /// What the coords chip prints. Falls back to the Mac proxy when
    /// no simulation is active so the chip isn't blank during plain
    /// browsing.
    private var displayedCoord: Coordinate? {
        // `currentMapFocus` resolves to browseCursor in Map mode
        // and simulatedLocation for a real iPhone — so the chip
        // shows the right point in either case.
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

    // ── times chip ───────────────────────────────────────────────

    /// Two stacked timestamps. Top is the Mac's wall clock; bottom is
    /// the wall clock at the simulated location's timezone. When the
    /// two timezones match (or we haven't yet learned the GPS tz) we
    /// hide the bottom row to save horizontal space.
    private var timesChip: some View {
        let tz = state.simulatedTimeZone
        let showRemote = tz != nil && tz != TimeZone.current
        return infoChip(
            content: {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: "macbook")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(formattedNow(in: TimeZone.current))
                    }
                    if showRemote, let tz {
                        HStack(spacing: 5) {
                            Image(systemName: "iphone.gen3")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(formattedNow(in: tz))
                            Text(tz.abbreviation() ?? tz.identifier)
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                }
            },
            help: LocalizedStringKey("Mac time / Time at the simulated location"),
        )
    }

    private func formattedNow(in tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        f.timeZone = tz
        return f.string(from: nowTick)
    }

    // MARK: - Helpers

    private var activeDevice: DeviceVM? {
        guard let udid = state.selectedUDID else { return nil }
        return state.devices.first(where: { $0.udid == udid })
    }
}
