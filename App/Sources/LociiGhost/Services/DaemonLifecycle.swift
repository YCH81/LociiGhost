import Foundation
#if canImport(Darwin)
import Darwin
#endif
import LociiGhostCore

/// Spawns and supervises the `lociighostd` Python helper as a child process.
///
/// Discovery order for the daemon executable:
///
/// 1. Bundle resource named `lociighostd` (when shipped as a packaged .app).
/// 2. The development venv at `~/Documents/LociiGhost/Daemon/.venv/bin/python -m lociighostd`.
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
                return "Could not locate lociighostd. Build the daemon first or place it next to the app."
            case .launchFailed(let s):
                return "Failed to launch lociighostd: \(s)"
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
        p.arguments = exe.arguments + ["--socket", LociiGhostPaths.socketPath]

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
        let logURL = LociiGhostPaths.logsDir.appending(path: "daemon-stdout.log")
        let errURL = LociiGhostPaths.logsDir.appending(path: "daemon-stderr.log")
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
        let path = LociiGhostPaths.socketPath
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
        // 1. Bundled PyInstaller daemon shipped inside the .app at
        //    Contents/Resources/lociighostd/lociighostd. This is the
        //    end-user path: anyone who downloads the DMG gets a
        //    self-contained daemon binary that doesn't need Python or
        //    a venv anywhere on disk. We check Bundle.main (the actual
        //    .app bundle) since the daemon dir is copied there by
        //    package-app.sh — it lives outside SwiftPM's
        //    Bundle.module resource bundle.
        //
        // `.absoluteURL` is load-bearing here: `Bundle.main.resourceURL`
        // is returned as a relative URL with a base
        // (`Contents/Resources/` relative to `file:///Applications/
        // LociiGhost.app/`). Chaining `.appending(path:)` on it produces
        // another relative URL. The modern `URL.path(percentEncoded:)`
        // API *does not resolve relative URLs against their base* — it
        // returns only the relative segment (e.g.
        // `"Contents/Resources/lociighostd/lociighostd"` with no
        // `/Applications/LociiGhost.app/` prefix). `FileManager.
        // isExecutableFile(atPath:)` then resolves that against `cwd`,
        // finds nothing, returns false, and we incorrectly fall through
        // to the staged-venv branch. The fall-through was the actual
        // shipped bug in v1.10.4 — daemon binary visibly present in the
        // .app, but the app reports "Could not locate lociighostd".
        // `.absoluteURL` collapses the base+relative URL into a single
        // absolute URL, so `.path(percentEncoded: false)` returns the
        // full POSIX path and `isExecutableFile` answers correctly.
        // (The deprecated `.path` getter happens to resolve too, which
        // is why `DaemonStaging.hasBundledDaemon` worked while this
        // function broke — same paths, different APIs, different
        // outcomes. Fixed in both places for consistency.)
        if let resources = Bundle.main.resourceURL {
            let bundled = resources
                .appending(path: "lociighostd")
                .appending(path: "lociighostd")
                .absoluteURL
            if FileManager.default.isExecutableFile(atPath: bundled.path(percentEncoded: false)) {
                return Resolved(url: bundled, arguments: [], pythonPathOverride: nil)
            }
        }

        // 2. Staged dev venv at `~/Library/Application Support/.../runtime`.
        //    macOS 15+ TCC blocks even root from reading `~/Documents`,
        //    so we never run the daemon directly from there. The staging
        //    step (DaemonStaging.ensureStaged) keeps a current copy in
        //    Application Support; root scripts can read that fine.
        //    Only reachable when the bundled daemon above isn't present
        //    — i.e. dev builds where package-app.sh wasn't given a
        //    Daemon/dist/ to bundle.
        let stagedPython = DaemonStaging.stagedPython
        let stagedSrc = DaemonStaging.stagedRoot
        if FileManager.default.isExecutableFile(atPath: stagedPython.path(percentEncoded: false)) {
            return Resolved(
                url: stagedPython,
                arguments: ["-m", "lociighostd"],
                pythonPathOverride: stagedSrc.path(percentEncoded: false),
            )
        }

        throw LifecycleError.daemonNotFound
    }
}
