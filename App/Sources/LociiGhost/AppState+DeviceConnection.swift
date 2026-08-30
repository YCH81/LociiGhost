import AppKit
import CoreLocation
import Foundation
import SwiftData
import Observation
import SwiftUI
import UniformTypeIdentifiers
import LociiGhostCore

// v1.15.2 audit (P12/Phase 7): split out of AppState.swift, which had
// reached 5449 lines across 37 MARK sections. These are extensions
// rather than separate types on purpose: every one of these methods
// reads or writes AppState's own SwiftData context and error surface,
// so extracting real types would mean deciding ownership of a dozen
// shared stored properties — a design change, not a refactor, and not
// one to make in the same pass as sixty bug fixes. The file boundary
// is what was actually costing time when navigating the class.

// Wi-Fi pairing, direct-IP connect, phone control, and Gold Ditto.

extension AppState {
    // MARK: - WiFi pairing + IP-direct connect

    /// Run the daemon's one-time `wifi.repair` ritual: USB autopair →
    /// CoreDeviceTunnelProxy → RSD → `create_core_device_tunnel_service_using_rsd(autopair=True)`
    /// which writes a fresh `~/.pymobiledevice3/remote_<UDID>.plist`.
    /// Two iOS Trust prompts appear during this; user must tap Trust on
    /// each. After this completes once, `connectWiFiByIP` works without
    /// the cable indefinitely.
    func pairForWiFi(udid: String? = nil) async {
        guard let client else { return }
        guard !isPairingForWiFi else { return }
        isPairingForWiFi = true
        defer { isPairingForWiFi = false }
        do {
            var params: [String: AnyCodable] = [:]
            if let udid { params["udid"] = AnyCodable(udid) }
            _ = try await client.callRaw("wifi.repair", params: params)
            lastError = nil
            // Pairing record is fresh — kick off discovery so the
            // newly-pairable iPhone appears in the WiFi list.
            await discoverWiFi()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Browse the LAN for paired iPhones (mDNS first, /24 TCP scan
    /// fallback). Stores results in `wifiCandidates` for the UI.
    func discoverWiFi() async {
        guard let client else { return }
        guard !isDiscoveringWiFi else { return }
        isDiscoveringWiFi = true
        defer { isDiscoveringWiFi = false }
        do {
            let raw: [WiFiCandidate] = try await client.call(
                "wifi.discover",
                params: ["scan_subnet": AnyCodable(true)]
            )
            wifiCandidates = raw
        } catch {
            wifiCandidates = []
            lastError = String(describing: error)
        }
    }

    /// Open the WiFi-connect selection sheet for `udid`. This is what
    /// the device row's "Connect via WiFi" button calls — instead of
    /// firing the legacy Bonjour-only connect path that returns a
    /// service-map-stripped RSD on iOS 26, the sheet auto-discovers
    /// LAN-reachable iPhones, lists them, and routes the user's pick
    /// through `connectWiFiByIP` (which opens the FULL RSD). If
    /// discovery returns nothing the sheet falls back to a manual
    /// IP entry field.
    func openWiFiConnectFlow(udid: String) {
        wifiConnectSheet = WiFiConnectSheetTarget(udid: udid)
        // Kick off a fresh discover so the sheet's list is current.
        // Fire-and-forget — the sheet's body re-renders as soon as
        // `wifiCandidates` updates.
        Task { await self.discoverWiFi() }
    }

    /// Connect to an iPhone discovered by `discoverWiFi()` (or any
    /// IP+port the user typed in manually). Uses the daemon's
    /// `wifi.connect_ip` which goes through
    /// `create_core_device_tunnel_service_using_remotepairing` directly,
    /// bypassing Bonjour at connect time and yielding the FULL RSD
    /// (with `dtservicehub`) — i.e. WiFi-only DVT location simulation
    /// works without a USB cable.
    ///
    /// On `-32004 TUNNEL_FAILED` (which on this path almost always
    /// means "iPhone moved to a different IP since the last
    /// discover"), kicks off a fresh `discoverWiFi()` automatically.
    /// The user sees the candidate list refresh and can click again
    /// without thinking about IP rotation.
    func connectWiFiByIP(ip: String, port: Int = 49152, udid: String? = nil) async {
        guard let client else { return }
        guard !isConnectingWiFiByIP else { return }
        isConnectingWiFiByIP = true
        defer { isConnectingWiFiByIP = false }
        do {
            var params: [String: AnyCodable] = [
                "ip": AnyCodable(ip),
                "port": AnyCodable(port),
            ]
            if let udid { params["udid"] = AnyCodable(udid) }
            _ = try await client.callRaw("wifi.connect_ip", params: params)
            lastError = nil
            await refreshDevices()
            // Same rationale as `connect()` — refresh the Mac
            // CoreLocation proxy now so Restore has a fresh fix.
            macLocation.requestPermissionAndFetch()
            // Successful Connect → full developer tunnel up → daemon is
            // exercising root utun, so admin signals are stale-clear.
            needsAdminElevation = false
            daemonIsRoot = true
        } catch {
            lastError = String(describing: error)
            if let rpc = error as? RPCError, rpc.code == -32004 {
                needsAdminElevation = true
            }
            // Tunnel failures on this path strongly correlate with the
            // iPhone having taken a new DHCP lease since we last
            // discovered. Fire-and-forget a refresh so the candidate
            // list is current next time the user clicks.
            Task { await self.discoverWiFi() }
        }
    }

    // MARK: - Phone control

    /// Candidate ports we walk when looking for the daemon's phone-
    /// control HTTP server. Must match `PORT_CANDIDATES` in
    /// `Daemon/lociighostd/http_server.py` — the daemon picks the
    /// first free one at startup, and this list is how we find
    /// where it actually landed without a separate RPC roundtrip.
    private static let phoneControlPorts: [Int] = [8779, 8780, 8781, 8788, 8789, 8800]

    /// Fetch the LAN URL + 6-digit PIN from the daemon's phone-control
    /// HTTP server. Walks the candidate-port list (the daemon may
    /// have fallen back from 8779 to 8780 etc. if a port was busy)
    /// and returns the first one that answers. The endpoint is
    /// localhost-only on the daemon, so we hit `127.0.0.1` directly
    /// over HTTP instead of going through our JSON-RPC socket.
    func fetchPhoneControlInfo() async {
        guard !isLoadingPhoneInfo else { return }
        isLoadingPhoneInfo = true
        defer { isLoadingPhoneInfo = false }
        for port in Self.phoneControlPorts {
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/phone/info")
            else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200
                else { continue }
                phoneControlInfo = try JSONDecoder().decode(PhoneControlInfo.self, from: data)
                return
            } catch {
                continue
            }
        }
        phoneControlInfo = nil
        lastError = "Phone control HTTP server isn't reachable on any candidate port (\(Self.phoneControlPorts.map(String.init).joined(separator: ", ")))."
    }

    /// Generate a fresh PIN + token. Invalidates any phone tab that
    /// was previously authed against the old token.
    func rotatePhoneControlPIN() async {
        // Use whichever port we already discovered — falls back to
        // re-walking the candidate list if we don't have one cached.
        let port: Int
        if let info = phoneControlInfo { port = info.port }
        else {
            await fetchPhoneControlInfo()
            guard let info = phoneControlInfo else { return }
            port = info.port
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/phone/rotate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            // v1.15.2 audit (X6): the response used to be discarded, so
            // the daemon-side 500 (it called a method that didn't
            // exist) read as success and the sheet re-displayed the
            // unchanged PIN. Surface the failure instead of implying
            // the old PIN was revoked when it wasn't.
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                lastError = String(localized: "Couldn't change the PIN — the old one is still active.")
                    + " (HTTP \(code))"
                return
            }
            await fetchPhoneControlInfo()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Open the phone-control sheet from anywhere in the UI. Auto-
    /// fetches info on appear so the sheet always shows current state.
    func openPhoneControlSheet() {
        showPhoneControlSheet = true
        Task { await fetchPhoneControlInfo() }
    }

    /// Ask the daemon to surface the Developer Mode toggle in iPhone Settings.
    /// Returns the next-step strings the daemon sent so the UI can show them.
    func revealDeveloperMode(udid: String) async -> [String] {
        guard let client else { return [] }
        struct Reply: Decodable { let ok: Bool; let next_steps: [String] }
        do {
            let reply: Reply = try await client.call("device.reveal_developer_mode",
                                                     params: ["udid": AnyCodable(udid)])
            return reply.next_steps
        } catch {
            lastError = String(describing: error)
            return []
        }
    }

    // MARK: - Gold Ditto (Pikmin Bloom 拉金盆 exploit, v1.4)

    /// Two-step burst: push iPhone GPS to A, then immediately
    /// clear so the iPhone reverts to real GPS. Used during a
    /// Pikmin Bloom gold-pot bud animation to fool the game into
    /// crediting the reward at the user's REAL location instead
    /// of the gold-pot's location — same gold pot can be milked
    /// repeatedly because the game records the "claim event" at
    /// A, not at the pot.
    ///
    /// Differs from a regular `teleport` + `restore`:
    ///
    ///   * Does NOT clear `pendingStops` / `navigation` /
    ///     `activeRoute` / `activeWaypoints` — the user might
    ///     have a route running and we don't want to disturb it
    ///   * Does NOT update `simulatedLocation` / fire the map fly
    ///     — desktop camera stays parked on the gold pot view
    ///   * Does NOT call any of the persistence hooks
    ///
    /// The whole point is "invisible round-trip from the desktop's
    /// perspective; only the phone's GPS actually moves."
    @MainActor
    func pullGoldDitto(udid: String, lat: Double, lng: Double) async {
        if udid == Self.virtualMapUDID {
            lastError = String(
                localized: "Gold Ditto needs a real iPhone connection.",
                comment: "Toast when the user fires Gold Ditto while the Map device is selected",
            )
            return
        }
        guard let client else { return }
        do {
            _ = try await client.callRaw("location.gold_ditto", params: [
                "udid": AnyCodable(udid),
                "lat":  AnyCodable(lat),
                "lng":  AnyCodable(lng),
            ])
        } catch {
            lastError = String(describing: error)
        }
    }

    // Moved here from the backup section (v1.15.2 audit, Phase 7):
    // it restarts the daemon and has nothing to do with backups.
    // It sat under a MARK whose title claimed it belonged to the
    // routes-JSON section, which is how it ended up there.
    /// Force-kill the running daemon and start a fresh one, requesting
    /// admin privileges through the standard macOS auth dialog. Used
    /// by the Settings sheet's "Force restart" button as a one-click
    /// recovery path so non-terminal users can recover from a stuck
    /// daemon without `kill` / `pkill` / `sudo` on the command line.
    ///
    /// Reuses `PrivilegedDaemonInstaller.install()` which already
    /// pkills any existing `-m lociighostd` process under both root
    /// and the user's uid before relaunching a clean daemon — exactly
    /// the same flow used during the very first launch, just with the
    /// app already up.
    @MainActor
    func forceRestartDaemon() async {
        // Disconnect locally before we ask the OS to kill the daemon
        // — the existing client's socket fd is about to become a
        // stale dangling reference. Setting `client = nil` flips the
        // UI to "Daemon disconnected" briefly, which is honest.
        if let existing = client {
            _ = try? await existing.callRaw("daemon.shutdown")
            await existing.disconnect()
        }
        client = nil
        // Use .starting — the existing DaemonStatus enum doesn't
        // carry a dedicated "restarting" case and the UI already
        // shows a sensible "Starting…" label for this state. No
        // need to widen the enum for a transient transition.
        daemonStatus = .starting

        do {
            try await PrivilegedDaemonInstaller.install()
            // PrivilegedDaemonInstaller.install() returns once the
            // socket exists; bootstrap() reconnects + re-hydrates
            // everything (device list, prefs, simulated location).
            // We re-set status to .stopped so bootstrap()'s guard
            // (`guard daemonStatus == .stopped`) lets it proceed.
            daemonStatus = .stopped
            await bootstrap()
            lastError = String(
                localized: "Daemon restarted successfully.",
                comment: "Toast after Force Restart finishes",
            )
        } catch PrivilegedDaemonInstaller.InstallError.userCancelled {
            // The user dismissed the auth dialog — reset status so
            // they can try again, and re-bootstrap to pick up any
            // pre-existing daemon that's still alive.
            daemonStatus = .stopped
            await bootstrap()
        } catch {
            daemonStatus = .stopped
            lastError = "Force restart failed: \(error.localizedDescription)"
        }
    }
}
