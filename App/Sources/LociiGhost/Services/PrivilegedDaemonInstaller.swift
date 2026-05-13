import AppKit
import Foundation
import LociiGhostCore

/// Spawn the `lociighostd` daemon as root **without ever asking the user
/// to open a terminal**.
///
/// The flow is the macOS-standard one:
/// 1. Write a small bootstrap shell script to a temp file.
/// 2. Hand that script to `osascript`'s
///    `do shell script "..." with administrator privileges`.
/// 3. macOS pops up its native authentication dialog (Touch ID / admin
///    password) — the same affordance Installer.app uses.
/// 4. On accept, our script kills any unprivileged daemon already
///    running and starts a fresh root daemon, detached, in the
///    background.
/// 5. We poll for the socket file to appear so the caller knows when
///    it's safe to (re)connect.
///
/// SMAppService / SMJobBless would be the long-term answer, but they
/// require Developer-ID code signing. For personal use this AppleScript
/// dance is the right level of friction (one click + Touch ID per
/// reboot).
@MainActor
enum PrivilegedDaemonInstaller {
    enum InstallError: LocalizedError {
        case userCancelled
        case scriptFailed(stderr: String, code: Int32)
        case socketDidNotAppear
        case daemonNotFound(URL)

        var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "Authentication was cancelled."
            case .scriptFailed(let s, let c):
                return s.isEmpty ? "Authentication helper exited with code \(c)." : s
            case .socketDidNotAppear:
                return "Daemon started but didn't open its socket within 10 seconds."
            case .daemonNotFound(let url):
                return "Couldn't find the daemon binary at \(url.path)."
            }
        }
    }

    /// Show the macOS admin auth dialog, then start `lociighostd` as root.
    /// Returns once the daemon's Unix socket has appeared.
    static func install() async throws {
        let layout = try resolveLayout()
        let scriptPath = try writeBootstrapScript(layout: layout)
        defer { try? FileManager.default.removeItem(at: scriptPath) }

        try await runAsAdmin(scriptPath: scriptPath)
        try await waitForSocket(at: layout.socketPath, timeout: 10)
    }

    // MARK: - Layout

    private struct Layout {
        let home: URL
        /// Direct path to the daemon executable that the bootstrap
        /// script will exec under sudo. For bundled .app installs
        /// this is the PyInstaller binary inside Contents/Resources/;
        /// for dev builds without that bundle it falls back to the
        /// staged venv's Python interpreter and we prepend
        /// `-m lociighostd` as an argument.
        let daemonExecutable: URL
        let daemonArguments: [String]
        /// When the daemon is the staged-venv Python, we need to
        /// inject PYTHONPATH for the import to resolve. nil when
        /// running the standalone PyInstaller binary.
        let pythonPath: String?
        let logFile: URL
        let socketDir: URL
        let socketPath: String
        let uid: uid_t
        let gid: gid_t
    }

    private static func resolveLayout() throws -> Layout {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Prefer the bundled PyInstaller binary inside the .app —
        // works for end users who downloaded the DMG, has no
        // dependency on Python being installed system-wide, and root
        // can read /Applications/LociiGhost.app/Contents/Resources/
        // without any TCC dance (unlike ~/Documents which macOS 15+
        // hides from root by default).
        let bundledDaemon: URL? = Bundle.main.resourceURL?
            .appending(path: "lociighostd")
            .appending(path: "lociighostd")

        let daemonExecutable: URL
        let daemonArguments: [String]
        let pythonPath: String?
        if let bundled = bundledDaemon,
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            daemonExecutable = bundled
            daemonArguments = []
            pythonPath = nil
        } else {
            // Dev-mode fallback: staged Python venv copy. macOS 15+'s
            // TCC blocks even root from reading ~/Documents without
            // an explicit Full Disk Access grant, so we always go
            // through DaemonStaging.stagedRoot, never directly at the
            // source under ~/Documents/.
            let stagedPython = DaemonStaging.stagedPython
            guard FileManager.default.fileExists(atPath: stagedPython.path) else {
                throw InstallError.daemonNotFound(stagedPython)
            }
            daemonExecutable = stagedPython
            daemonArguments = ["-m", "lociighostd"]
            pythonPath = DaemonStaging.stagedRoot.path
        }

        let logDir = home.appending(path: "Library/Logs/LociiGhost",
                                    directoryHint: .isDirectory)
        let socketDir = home.appending(path: "Library/Application Support/LociiGhost",
                                       directoryHint: .isDirectory)
        return Layout(
            home: home,
            daemonExecutable: daemonExecutable,
            daemonArguments: daemonArguments,
            pythonPath: pythonPath,
            logFile: logDir.appending(path: "lociighostd-sudo.log"),
            socketDir: socketDir,
            socketPath: LociiGhostPaths.socketPath,
            uid: getuid(),
            gid: getgid()
        )
    }

    // MARK: - Script generation

    private static func writeBootstrapScript(layout: Layout) throws -> URL {
        // Single-quoted POSIX escape so any path with spaces or quotes
        // survives the trip through both osascript and the shell.
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        // Build the env-var prefix + command line. The bundled
        // PyInstaller binary doesn't need PYTHONPATH; the dev-mode
        // Python interpreter does. Building both branches here keeps
        // the heredoc itself agnostic.
        let envLine: String
        if let pythonPath = layout.pythonPath {
            envLine = "PYTHONPATH=" + q(pythonPath) + " \\\n            "
        } else {
            envLine = ""
        }
        let daemonArgs = layout.daemonArguments
            .map { q($0) }
            .joined(separator: " ")
        let daemonCmd = daemonArgs.isEmpty
            ? q(layout.daemonExecutable.path)
            : q(layout.daemonExecutable.path) + " " + daemonArgs
        // pkill matchers need to find the running daemon regardless of
        // which launch path produced it. The bundled PyInstaller path
        // shows up in `ps` with its absolute /Applications/.../lociighostd
        // command line; the dev-mode Python path shows up as
        // `<...>/Python -m lociighostd`. Match on either basename so
        // either launch leaves no zombies.
        let pkillPattern = "lociighostd"

        // Bootstrap script. Heavily traced — every step logs to the
        // sudo daemon log file (`logFile`) before doing the work, so
        // when something goes wrong the log itself tells us which step
        // failed instead of leaving an empty file behind.
        let body = """
        #!/bin/bash
        LOG=\(q(layout.logFile.path))
        log() { printf '[%s] %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }
        log "===== privileged install start ====="
        log "uid=$(id -u) euid=$(id -un) home=$HOME"
        log "daemon: \(layout.daemonExecutable.path)"
        mkdir -p \(q(layout.socketDir.path)) \(q(layout.logFile.deletingLastPathComponent().path)) || log "mkdir failed: $?"
        log "killing any prior lociighostd..."
        # Match on the basename `lociighostd` — covers both the
        # bundled PyInstaller binary (whose argv[0] ends in
        # /lociighostd) and the Python dev-mode invocation (which
        # shows up as `Python -m lociighostd` in ps -f, matching via
        # the `-m` substring).
        # First TERM (graceful), short pause, then KILL.
        pkill -TERM -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched TERM (root)"
        pkill -TERM -u \(layout.uid) -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched TERM (uid=\(layout.uid))"
        sleep 0.5
        pkill -KILL -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched KILL (root)"
        pkill -KILL -u \(layout.uid) -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched KILL (uid=\(layout.uid))"
        sleep 0.2
        log "post-kill survivors: $(pgrep -fl '\(pkillPattern)' || echo none)"
        log "removing stale socket..."
        rm -f \(q(layout.socketPath)) >>"$LOG" 2>&1 || true
        log "spawning daemon..."
        # Daemonize via a child shell that exec()s the daemon with
        # stdin redirected to /dev/null. Backgrounding from a *fresh*
        # shell means osascript sees a zero-exit-status parent and our
        # daemon is no longer attached to the osascript pty.
        (
          exec </dev/null
          HOME=\(q(layout.home.path)) \\
            SUDO_UID=\(layout.uid) \\
            SUDO_GID=\(layout.gid) \\
            \(envLine)\(daemonCmd) >>"$LOG" 2>&1 &
          disown
        )
        log "spawn returned $?; sleeping 0.4s"
        sleep 0.4
        log "checking socket existence: $(ls -la \(q(layout.socketPath)) 2>&1)"
        log "===== privileged install done ====="
        """

        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "lociighost-elevate-\(UUID().uuidString).sh")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: tmp.path
        )
        return tmp
    }

    // MARK: - osascript bridge

    private static func runAsAdmin(scriptPath: URL) async throws {
        // `quoted form of` is AppleScript's own POSIX-escape for paths,
        // so we don't have to backslash-escape anything ourselves.
        let appleScript = """
        do shell script (quoted form of "\(scriptPath.path)") with administrator privileges
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()
        await Task.detached { process.waitUntilExit() }.value

        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.availableData
            let raw = String(data: data, encoding: .utf8) ?? ""
            // osascript exits 1 with "User cancelled. (-128)" when the
            // user closes the auth dialog. Differentiate that from a
            // real failure so the GUI can stay quiet on cancellation.
            if raw.contains("User cancelled") || raw.contains("(-128)") {
                throw InstallError.userCancelled
            }
            throw InstallError.scriptFailed(stderr: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                            code: process.terminationStatus)
        }
    }

    // MARK: - Wait for socket

    private static func waitForSocket(at path: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw InstallError.socketDidNotAppear
    }
}
