import Foundation
#if canImport(Darwin)
import Darwin
#endif
import LocWarpCore

/// Spawns and supervises the `locwarpd` Python helper as a child process.
///
/// Discovery order for the daemon executable:
///
/// 1. Bundle resource named `locwarpd` (when shipped as a packaged .app).
/// 2. The development venv at `~/Documents/LocWarp.Mac/Daemon/.venv/bin/python -m locwarpd`.
///
/// Phase 1 keeps this deliberately simple: the app spawns one daemon
/// instance, owns its lifetime, and kills it on `stop()`. Later phases
/// can switch to a launchd-managed daemon for the WiFi-tunnel flow that
/// needs root.
final class DaemonLifecycle {
    enum LifecycleError: Error, CustomStringConvertible {
        case daemonNotFound
        case launchFailed(String)

        var description: String {
            switch self {
            case .daemonNotFound:
                return "Could not locate locwarpd. Build the daemon first or place it next to the app."
            case .launchFailed(let s):
                return "Failed to launch locwarpd: \(s)"
            }
        }
    }

    private var process: Process?
    private(set) var attachedToExisting = false

    func start() throws {
        guard process == nil else { return }

        // If a daemon is already running on the standard socket -- typically
        // because the user launched it manually with sudo for the iOS 17+
        // tunnel work -- attach to it instead of spawning our own. The app
        // will not own this daemon's lifetime; stop() leaves it running.
        if isExistingSocketResponsive() {
            attachedToExisting = true
            return
        }

        let exe = try resolveExecutable()
        let p = Process()
        p.executableURL = exe.url
        p.arguments = exe.arguments + ["--socket", LocWarpPaths.socketPath]

        // macOS Sequoia auto-flags files in ~/Documents/ as UF_HIDDEN, and
        // Python 3.13's site.py refuses to load hidden .pth files — so editable
        // pip installs in this project's venv silently fail with
        // ModuleNotFoundError. Sidestep the whole .pth dance by injecting the
        // daemon source directory into PYTHONPATH explicitly.
        if let pythonPath = exe.pythonPathOverride {
            var env = ProcessInfo.processInfo.environment
            if let existing = env["PYTHONPATH"], !existing.isEmpty {
                env["PYTHONPATH"] = "\(pythonPath):\(existing)"
            } else {
                env["PYTHONPATH"] = pythonPath
            }
            p.environment = env
        }

        // Keep stdout/stderr connected to the log file rather than the GUI app.
        let logURL = LocWarpPaths.logsDir.appending(path: "daemon-stdout.log")
        let errURL = LocWarpPaths.logsDir.appending(path: "daemon-stderr.log")
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: errURL.path(percentEncoded: false), contents: nil)
        p.standardOutput = try FileHandle(forWritingTo: logURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        do {
            try p.run()
        } catch {
            throw LifecycleError.launchFailed(String(describing: error))
        }
        process = p
    }

    func stop() {
        if attachedToExisting {
            // We didn't spawn this daemon (a sudo'd one was already running),
            // so leave it alone -- the user will stop it themselves.
            attachedToExisting = false
            return
        }
        guard let p = process else { return }
        process = nil
        if p.isRunning {
            // SIGTERM first — the daemon installs a handler that drains the
            // socket and clears any active simulation. SIGKILL only if it's
            // still alive a bit later.
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// True if the canonical socket exists and a connect()+close() succeeds.
    /// We don't ping; merely opening the socket is enough proof the file
    /// belongs to a live process and isn't a stale leftover from a crash.
    private func isExistingSocketResponsive() -> Bool {
        let path = LocWarpPaths.socketPath
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { cp in
                for (i, b) in bytes.enumerated() { cp[i] = CChar(bitPattern: b) }
                cp[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(s, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    // MARK: - Discovery

    private struct Resolved {
        let url: URL
        let arguments: [String]
        /// If non-nil, prepended to PYTHONPATH so a dev install can be found
        /// without relying on .pth files (see start() for why).
        let pythonPathOverride: String?
    }

    private func resolveExecutable() throws -> Resolved {
        // 1. Bundled native binary (PyInstaller output).
        if let bundled = Bundle.module.url(forResource: "locwarpd", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path(percentEncoded: false)) {
            return Resolved(url: bundled, arguments: [], pythonPathOverride: nil)
        }

        // 2. Staged dev venv at `~/Library/Application Support/.../runtime`.
        //    macOS 15+ TCC blocks even root from reading `~/Documents`,
        //    so we never run the daemon directly from there. The staging
        //    step (DaemonStaging.ensureStaged) keeps a current copy in
        //    Application Support; root scripts can read that fine.
        let stagedPython = DaemonStaging.stagedPython
        let stagedSrc = DaemonStaging.stagedRoot
        if FileManager.default.isExecutableFile(atPath: stagedPython.path(percentEncoded: false)) {
            return Resolved(
                url: stagedPython,
                arguments: ["-m", "locwarpd"],
                pythonPathOverride: stagedSrc.path(percentEncoded: false),
            )
        }

        throw LifecycleError.daemonNotFound
    }
}
