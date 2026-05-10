import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    MapContainerView()
                        .ignoresSafeArea(edges: .top)

                    VStack(alignment: .leading, spacing: 10) {
                        // Top strip: leave room for MapKit's scale on the
                        // far left, search bar in the middle, quick
                        // recenter button on the right (offset enough to
                        // clear MapKit's compass).
                        HStack(alignment: .top, spacing: 12) {
                            Spacer().frame(width: 200)
                            MapSearchBar()
                            Spacer(minLength: 12)
                            QuickRecenterButton()
                                .padding(.trailing, 44)
                        }
                        Overlay()
                    }
                    .padding(12)
                }
                BottomBar()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("LociiGhost")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DaemonStatusPill()
            }
        }
        // Drive route-preview refreshes from here so the view layer's
        // observation of `pendingStops` / `useStraightLine` does the work
        // — `didSet` on those properties wouldn't fire reliably under the
        // @Observable macro for in-place array mutations.
        .onChange(of: state.pendingStops) { _, _ in
            state.schedulePreviewRefresh()
        }
        .onChange(of: state.useStraightLine) { _, _ in
            state.schedulePreviewRefresh()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                Button {
                    Task { await state.refreshDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh device list")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Divider().padding(.vertical, 8)

            if state.devices.isEmpty {
                ContentUnavailableView {
                    Label("No iPhone connected", systemImage: "iphone.slash")
                } description: {
                    Text("Plug an iPhone into USB and tap **Trust this computer** when prompted.")
                        .font(.caption)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(state.devices, selection: $state.selectedUDID) { device in
                    DeviceRow(device: device)
                        .tag(device.udid)
                }
                .listStyle(.sidebar)
            }

            Divider()

            WiFiSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // Movement Modes sits ABOVE System Functions: it's the
            // primary day-to-day surface (changing how the iPhone
            // moves) whereas System Functions is one-time setup
            // (Developer Mode toggle).
            MovementModesSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            SystemSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 260)
        // Sheet attached at the sidebar root so it presents above the
        // whole UI, not inside a small device row. AppState owns the
        // `wifiConnectSheet` target; the sheet sets it back to nil to
        // dismiss.
        .sheet(item: Binding(
            get: { state.wifiConnectSheet },
            set: { state.wifiConnectSheet = $0 }
        )) { target in
            WiFiConnectSheet(target: target)
                .environment(state)
        }
    }
}

/// Sidebar section for the M-style WiFi-only flow: a one-shot "Pair
/// for WiFi" that mints a fresh `~/.pymobiledevice3/remote_<UDID>.plist`
/// (USB cable required *only* for this single ritual), then a list of
/// LAN-discovered iPhones the user can Connect to without the cable.
private struct WiFiSection: View {
    @Environment(AppState.self) private var state

    /// Any device in the sidebar list whose pair record is missing —
    /// determines whether the Pair button should be inviting or muted.
    private var hasUnpairedDevice: Bool {
        state.devices.contains { !$0.isWiFiPaired }
    }
    /// True if every device we know about is already WiFi-paired AND
    /// at least one such device exists. Used to render the button as
    /// "Already paired" instead of nudging the user to re-run.
    private var allPairedAlready: Bool {
        !state.devices.isEmpty && state.devices.allSatisfy { $0.isWiFiPaired }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WiFi Devices")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    Task { await state.discoverWiFi() }
                } label: {
                    if state.isDiscoveringWiFi {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(state.isDiscoveringWiFi)
                .help("Scan LAN for paired iPhones")
            }

            pairButton

            // Two-stage progress indicator while the pair RPC is in
            // flight. Driven by `event.wifi_pair_progress` events the
            // daemon broadcasts at each handshake step.
            if let progress = state.pairProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text(progress.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            // Discovery results — empty state until user clicks
            // refresh OR pair-for-wifi (which auto-discovers on
            // success). nil distinguishes "haven't browsed yet" from
            // "browsed and found nothing".
            if let candidates = state.wifiCandidates {
                if candidates.isEmpty {
                    Text("No iPhones found on the LAN. Make sure the iPhone is on the same Wi-Fi and you've run **Pair for WiFi** once. You can also enter an IP manually below.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    ForEach(candidates) { c in
                        WiFiCandidateRow(candidate: c)
                    }
                }
            }

            // Manual IP entry — fallback for the case where mDNS
            // discovery missed the iPhone AND the /24 scan didn't
            // pick it up either (e.g. the iPhone is on a different
            // subnet but reachable via routed VPN).
            ManualIPEntry()
                .padding(.top, 6)
        }
    }

    /// Button label / state computed from sidebar's wifi_paired field
    /// and any in-flight pair operation. Three resting states:
    ///
    /// * No devices visible OR at least one unpaired → "Pair for WiFi"
    /// * Every visible device already has a remote pair record →
    ///   "Already paired · Re-pair…" (less prominent — clicking still
    ///   works for emergencies but it's no longer the primary CTA)
    /// * Pair RPC in flight → "Pairing…" with the live progress
    ///   message slot (the actual progress bar lives below)
    @ViewBuilder
    private var pairButton: some View {
        Button {
            Task { await state.pairForWiFi() }
        } label: {
            HStack(spacing: 8) {
                if state.isPairingForWiFi {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: allPairedAlready
                          ? "checkmark.seal.fill"
                          : "key.radiowaves.forward.fill")
                        .foregroundStyle(allPairedAlready ? Color.green : Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    pairButtonTitleText
                        .font(.body)
                    pairButtonSubtitleText
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .opacity(allPairedAlready && !state.isPairingForWiFi ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(state.isPairingForWiFi)
    }

    /// Inline @ViewBuilder so each branch's `Text("literal")` is a real
    /// `LocalizedStringKey` and gets translated by the env locale.
    /// (The earlier `Text(stringFunction())` form passed a plain
    /// `String`, which SwiftUI shows verbatim — so the picker did
    /// nothing for these specific labels.)
    @ViewBuilder
    private var pairButtonTitleText: some View {
        if state.isPairingForWiFi {
            Text("Pairing…")
        } else if allPairedAlready {
            Text("Already paired · Re-pair…",
                 comment: "Pair-for-WiFi button title when pair record already exists")
        } else {
            Text("Pair for WiFi",
                 comment: "Sidebar button — runs the M-style RemotePairing setup ritual")
        }
    }

    @ViewBuilder
    private var pairButtonSubtitleText: some View {
        if state.isPairingForWiFi {
            // The progress message is a daemon-emitted English string
            // and doesn't pass through Localizable.strings — that's
            // intentional, since translating daemon output would mean
            // sending a locale param down the RPC and per-locale Python
            // strings. For Phase 5.1 the live progress message stays
            // English; the static fallback below honours the locale.
            if let progressMessage = state.pairProgress?.message {
                Text(verbatim: progressMessage)
            } else {
                Text("Tap Trust on iPhone when prompted.",
                     comment: "Pair button subtitle while RPC is in flight but no progress event yet")
            }
        } else if allPairedAlready {
            Text("Pair record on disk. Click only if WiFi connect stops working — generates a fresh record.",
                 comment: "Pair button subtitle when already paired")
        } else {
            Text("Plug iPhone in once. Two Trust prompts will appear; after that, WiFi works without the cable.",
                 comment: "Pair button subtitle for first-time pairing")
        }
    }
}

private struct WiFiCandidateRow: View {
    let candidate: WiFiCandidate
    @Environment(AppState.self) private var state

    /// Match precisely by (peer_ip, peer_port) so only THE row that
    /// originated the active session flips into "Connected" state.
    /// Fixed in v0.2.10 — earlier versions matched on
    /// "any network-connected device" which lit up every row when
    /// the user had multiple discovered candidates for the same
    /// iPhone (DHCP floating, multi-NIC, etc.).
    private var matchedSession: DeviceVM? {
        state.devices.first { dev in
            dev.connected
                && dev.transport == "network"
                && dev.peer_ip == candidate.ip
                && dev.peer_port == candidate.port
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .foregroundStyle(matchedSession != nil ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(matchedSession?.name ?? candidate.name)
                        .font(.callout)
                    if matchedSession != nil {
                        Text("Connected",
                             comment: "Capsule badge on a WiFi candidate row that's the active session")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green, in: .capsule)
                    }
                }
                Text("\(candidate.ip):\(candidate.port) · \(candidate.method)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let session = matchedSession {
                Button("Disconnect") {
                    Task { await state.disconnect(udid: session.udid) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if state.isConnectingWiFiByIP {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect") {
                    Task {
                        await state.connectWiFiByIP(
                            ip: candidate.ip, port: candidate.port
                        )
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Manual IP-and-port entry, for when neither mDNS nor the /24 TCP
/// scan picked the iPhone up — e.g. iPhone on a different subnet
/// reachable through routed VPN, or some unusual NAT layout. The
/// daemon's `wifi.connect_ip` accepts arbitrary `(ip, port)`; this
/// view just gives the user a way to feed that path without typing
/// JSON-RPC by hand.
/// Modal sheet shown when the user clicks "Connect via WiFi" from a
/// device row. Auto-discovers iPhones on the LAN, lists them as
/// click-to-connect rows, and falls back to a manual IP-entry form
/// when discovery returns nothing. Dismisses on a successful connect
/// or when the user cancels.
private struct WiFiConnectSheet: View {
    let target: WiFiConnectSheetTarget
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var manualIP: String = ""
    @State private var manualPort: String = "49152"
    @State private var didDiscover: Bool = false

    private var matchingDevice: DeviceVM? {
        state.devices.first(where: { $0.udid == target.udid })
    }
    private var isDiscovering: Bool { state.isDiscoveringWiFi }
    private var candidates: [WiFiCandidate] { state.wifiCandidates ?? [] }
    private var portInt: Int? {
        Int(manualPort.trimmingCharacters(in: .whitespaces))
    }
    private var ipIsPlausible: Bool {
        let parts = manualIP.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { (Int($0) ?? -1) >= 0 && (Int($0) ?? -1) <= 255 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "wifi")
                    .foregroundStyle(.tint)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect via WiFi")
                        .font(.headline)
                    if let dev = matchingDevice {
                        Text("Looking for \(dev.name) on the LAN…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await state.discoverWiFi() }
                } label: {
                    if isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isDiscovering)
                .help("Re-scan LAN")
            }

            Divider()

            // Body — three states: scanning / candidates / empty.
            Group {
                if isDiscovering && candidates.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Scanning LAN for paired iPhones…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Found \(candidates.count) device\(candidates.count == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(candidates) { c in
                            sheetCandidateRow(c)
                        }
                    }
                } else {
                    // didDiscover && empty: prompt for manual IP.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text("No iPhones found on the LAN.")
                                .font(.callout)
                        }
                        Text("Make sure the iPhone is on the same Wi-Fi and that you've already done **Pair for WiFi** for it once. If you know the IP, enter it below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Manual IP fallback — always available, but the prompt
            // text above only nudges towards it when discovery
            // returned nothing.
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Or enter IP manually")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("192.168.0.123", text: $manualIP)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    Text(":").foregroundStyle(.secondary)
                    TextField("49152", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 70)
                    Spacer(minLength: 4)
                    Button("Connect") {
                        guard let p = portInt else { return }
                        let ip = manualIP
                        Task {
                            await state.connectWiFiByIP(
                                ip: ip, port: p, udid: target.udid
                            )
                            await MainActor.run { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!ipIsPlausible || portInt == nil
                              || state.isConnectingWiFiByIP)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
        .task {
            // Auto-discover on first appearance. Subsequent re-opens
            // re-use the existing wifiCandidates (if any) — user can
            // tap the refresh button in the header to force-re-scan.
            if !didDiscover {
                didDiscover = true
                if state.wifiCandidates == nil
                    || (state.wifiCandidates?.isEmpty ?? true) {
                    await state.discoverWiFi()
                }
            }
        }
    }

    @ViewBuilder
    private func sheetCandidateRow(_ c: WiFiCandidate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.callout)
                Text("\(c.ip):\(c.port) · \(c.method)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isConnectingWiFiByIP {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect") {
                    let ip = c.ip
                    let port = c.port
                    Task {
                        await state.connectWiFiByIP(
                            ip: ip, port: port, udid: target.udid
                        )
                        await MainActor.run { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }
}

private struct ManualIPEntry: View {
    @Environment(AppState.self) private var state
    @State private var ip: String = ""
    @State private var port: String = "49152"

    private var ipIsPlausible: Bool {
        // Loose: 4 dot-separated digit groups, each 1-3 chars.
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            let n = Int($0) ?? -1
            return n >= 0 && n <= 255
        }
    }
    private var portInt: Int? {
        Int(port.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("192.168.0.123", text: $ip)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("49152", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 60)
                    Spacer(minLength: 4)
                    Button("Connect") {
                        guard let p = portInt else { return }
                        Task {
                            await state.connectWiFiByIP(ip: ip, port: p)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!ipIsPlausible || portInt == nil
                              || state.isConnectingWiFiByIP)
                }
                Text("Use when the iPhone isn't picked up by auto-discover (different subnet, VPN, etc.). Default port for RemotePairing is 49152.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } label: {
            Text("Manual IP entry")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Sidebar block below the device list. Houses things that aren't tied to
/// a specific device row but still belong to the device-management surface
/// — the most common one being "Enable Developer Mode" which the user may
/// want to trigger manually even when our auto-detection didn't flag it.
private struct SystemSection: View {
    @Environment(AppState.self) private var state
    @State private var showingDevModeSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Functions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                showingDevModeSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hammer.circle.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Enable Developer Mode…")
                            .font(.body)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(selectedDevice == nil)
            .sheet(isPresented: $showingDevModeSheet) {
                if let dev = selectedDevice {
                    DeveloperModeSheet(device: dev)
                        .environment(state)
                }
            }
        }
    }

    private var selectedDevice: DeviceVM? {
        guard let udid = state.selectedUDID else { return nil }
        return state.devices.first(where: { $0.udid == udid })
    }

    private var subtitle: String {
        if let dev = selectedDevice {
            if dev.developer_mode == true {
                return "Already on for \(dev.name)."
            }
            return "Walk through enabling on \(dev.name)."
        }
        return "Select a device first."
    }
}

private struct DeviceRow: View {
    let device: DeviceVM
    @Environment(AppState.self) private var state
    @State private var showingDevModeSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: device.isUSB ? "iphone" : "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(device.connected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.name).font(.body)
                        if isLikelyOffline {
                            // After health-check disconnects an
                            // unreachable WiFi device, the entry sticks
                            // around (we still have a pair record on
                            // disk, so it's NOT really gone — just not
                            // talking to us right now). Without an
                            // explicit "No active connection" tag the
                            // entry looks identical to a healthy
                            // disconnected device and the user can't
                            // tell why Connect immediately fails.
                            Text("No active connection",
                                 comment: "Capsule badge on a device row whose iPhone is offline")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.gray, in: .capsule)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("iOS \(device.iosVersion)")
                        Text("·")
                        transportBadges(for: device)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(devModeColor(for: device))
                            .frame(width: 6, height: 6)
                        Text(device.developerModeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                connectAction(for: device)
            }

            if device.developerModeNeedsAttention {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Developer Mode is off")
                        .font(.caption)
                    Button("Enable…") {
                        showingDevModeSheet = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingDevModeSheet) {
            DeveloperModeSheet(device: device)
                .environment(state)
        }
    }

    /// Heuristic: a device with a stored WiFi pair record but no
    /// active session and no transport other than "network" (i.e. not
    /// in usbmuxd right now) is almost certainly offline. The
    /// background health check at v0.2.10 also clears active sessions
    /// the moment the iPhone stops responding, which is what flips
    /// most rows into this state. We still let the user click Connect
    /// — we just stop pretending the connection is one button-press
    /// away from working.
    private var isLikelyOffline: Bool {
        guard !device.connected else { return false }
        // USB-discovered devices are never "offline" in this sense
        // — usbmuxd is reporting them right now, so a Connect should
        // succeed.
        if device.supportsUSB { return false }
        // The device exists in the list at all only because of the
        // wifi-paired path (pair record on disk). With nothing live,
        // we can't promise it's reachable.
        return device.isWiFiPaired
    }

    private func devModeColor(for device: DeviceVM) -> Color {
        switch device.developer_mode {
        case .some(true):  return .green
        case .some(false): return .orange
        case .none:        return .secondary
        }
    }

    /// Renders one capsule per transport usbmuxd currently sees for the
    /// device. The capsule for the *active* transport is filled in green
    /// when connected; idle transports stay neutral.
    @ViewBuilder
    private func transportBadges(for device: DeviceVM) -> some View {
        HStack(spacing: 3) {
            if device.supportsUSB {
                badgeChip(label: "USB",
                          highlight: device.connected && device.transport == "usb")
            }
            if device.supportsWiFi {
                badgeChip(label: "WiFi",
                          highlight: device.connected && device.transport == "network")
            }
            if !device.supportsUSB && !device.supportsWiFi {
                Text(device.transport.uppercased())
            }
        }
    }

    private func badgeChip(label: String, highlight: Bool) -> some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                highlight ? AnyShapeStyle(Color.green.opacity(0.22))
                          : AnyShapeStyle(Color.secondary.opacity(0.15)),
                in: .capsule
            )
            .foregroundStyle(highlight ? Color.green : Color.secondary)
    }

    /// Connect/Disconnect control. Becomes a menu when both USB and WiFi
    /// are available, so the user can pick the transport explicitly
    /// without unplugging the USB cable. WiFi entries route through
    /// the WiFiConnectSheet (which auto-discovers and lets the user
    /// pick an IP) instead of the legacy Bonjour-only path that on
    /// iOS 26 returns a service-map-stripped RSD.
    @ViewBuilder
    private func connectAction(for device: DeviceVM) -> some View {
        if device.connected {
            Button("Disconnect") {
                Task { await state.disconnect(udid: device.udid) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } else if device.supportsUSB && device.supportsWiFi {
            Menu {
                Button {
                    Task { await state.connect(udid: device.udid, preferWiFi: false) }
                } label: {
                    Label("Connect via USB", systemImage: "cable.connector")
                }
                Button {
                    state.openWiFiConnectFlow(udid: device.udid)
                } label: {
                    Label("Connect via WiFi", systemImage: "wifi")
                }
            } label: {
                Text("Connect")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .font(.caption)
        } else if device.supportsWiFi {
            Button("Connect via WiFi") {
                state.openWiFiConnectFlow(udid: device.udid)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } else {
            Button("Connect") {
                Task {
                    await state.connect(udid: device.udid, preferWiFi: false)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

private struct DaemonStatusPill: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("lociighostd: \(state.daemonStatus.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !state.daemonVersion.isEmpty {
                Text("v\(state.daemonVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var color: Color {
        switch state.daemonStatus {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }
}

private struct Overlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdminPromptBanner()
            if !state.pendingStops.isEmpty,
               let udid = state.selectedUDID {
                ControlPanel(udid: udid)
            }
            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .padding(8)
                    .background(.red.opacity(0.15), in: .rect(cornerRadius: 6))
            }
        }
    }
}
