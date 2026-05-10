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
        .navigationTitle("LocWarp")
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
                    Text(device.name).font(.body)
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
    /// without unplugging the USB cable.
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
                    Task { await state.connect(udid: device.udid, preferWiFi: true) }
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
        } else {
            Button(device.supportsWiFi ? "Connect via WiFi" : "Connect") {
                Task {
                    await state.connect(udid: device.udid,
                                        preferWiFi: device.supportsWiFi && !device.supportsUSB)
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
            Text("locwarpd: \(state.daemonStatus.label)")
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
