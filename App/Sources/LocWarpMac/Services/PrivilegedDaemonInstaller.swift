import AppKit
import Foundation
import LocWarpCore

/// Spawn the `locwarpd` daemon as root **without ever asking the user
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

    /// Show the macOS admin auth dialog, then start `locwarpd` as root.
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
        let projectDir: URL
        let venvPython: URL
        let logFile: URL
        let socketDir: URL
        let socketPath: String
        let uid: uid_t
        let gid: gid_t
    }

    private static func resolveLayout() throws -> Layout {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // We deliberately point at the *staged* tree under
        // `~/Library/Application Support/`, not the developer source
        // under `~/Documents/`. macOS 15+'s TCC blocks even root from
        // reading ~/Documents without an explicit Full Disk Access
        // grant, which would defeat the whole "no terminal needed" UX.
        let projectDir = DaemonStaging.stagedRoot.deletingLastPathComponent()
        let venvPython = DaemonStaging.stagedPython
        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            throw InstallError.daemonNotFound(venvPython)
        }
        let logDir = home.appending(path: "Library/Logs/LocWarp.Mac",
                                    directoryHint: .isDirectory)
        let socketDir = home.appending(path: "Library/Application Support/LocWarp.Mac",
                                       directoryHint: .isDirectory)
        return Layout(
            home: home,
            projectDir: projectDir,
            venvPython: venvPython,
            logFile: logDir.appending(path: "locwarpd-sudo.log"),
            socketDir: socketDir,
            socketPath: LocWarpPaths.socketPath,
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

        // Bootstrap script. Heavily traced — every step logs to the
        // sudo daemon log file (`logFile`) before doing the work, so
        // when something goes wrong the log itself tells us which step
        // failed instead of leaving an empty file behind.
        //
        // We split daemon launch into two stages:
        // 1. Inner script `bootstrap-inner.sh` does the actual work
        //    (env vars + nohup + redirects).
        // 2. Outer script execs the inner one detached via `setsid` if
        //    available, falling back to `nohup`. setsid is preferable
        //    under osascript because it creates a brand-new session
        //    not tied to the pty osascript opened.
        let body = """
        #!/bin/bash
        LOG=\(q(layout.logFile.path))
        log() { printf '[%s] %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }
        log "===== privileged install start ====="
        log "uid=$(id -u) euid=$(id -un) home=$HOME"
        mkdir -p \(q(layout.socketDir.path)) \(q(layout.logFile.deletingLastPathComponent().path)) || log "mkdir failed: $?"
        log "killing any prior locwarpd..."
        # The daemon is invoked as `<...>/Python -m locwarpd` — note
        # the CAPITAL P on Homebrew's binary name. Earlier versions of
        # this script tried to match `'python -m locwarpd'` (lowercase)
        # and silently caught nothing, so every Authenticate cycle
        # leaked an entire daemon process (3+ root daemons routinely
        # alive after a single Mac session). Match on `-m locwarpd`
        # which is invariant across binary capitalisation.
        #
        # We also have to kill user-mode daemons that DaemonLifecycle
        # spawned. The bare `pkill -f` here runs as root and matches
        # processes regardless of owner, so the second variant with
        # `-u USER_UID` is redundant — but cheap, and it self-documents
        # that we explicitly want to clear the original user's daemons
        # too. USER_UID is baked in at script-generation time because
        # osascript-with-admin-privileges doesn't reliably pass SUDO_UID
        # through.
        # First TERM (graceful), short pause, then KILL.
        pkill -TERM -f '\\-m locwarpd' >>"$LOG" 2>&1 \\
          || log "no daemons matched TERM (root)"
        pkill -TERM -u \(layout.uid) -f '\\-m locwarpd' >>"$LOG" 2>&1 \\
          || log "no daemons matched TERM (uid=\(layout.uid))"
        sleep 0.5
        pkill -KILL -f '\\-m locwarpd' >>"$LOG" 2>&1 \\
          || log "no daemons matched KILL (root)"
        pkill -KILL -u \(layout.uid) -f '\\-m locwarpd' >>"$LOG" 2>&1 \\
          || log "no daemons matched KILL (uid=\(layout.uid))"
        sleep 0.2
        log "post-kill survivors: $(pgrep -fl '\\-m locwarpd' || echo none)"
        log "removing stale socket..."
        rm -f \(q(layout.socketPath)) >>"$LOG" 2>&1 || true
        log "spawning daemon..."
        # Daemonize via a child shell that exec()s python with stdin
        # redirected to /dev/null. Backgrounding from a *fresh* shell
        # means osascript sees a zero-exit-status parent and our daemon
        # is no longer attached to the osascript pty.
        (
          exec </dev/null
          HOME=\(q(layout.home.path)) \\
            SUDO_UID=\(layout.uid) \\
            SUDO_GID=\(layout.gid) \\
            PYTHONPATH=\(q(layout.projectDir.appending(path: "Daemon").path)) \\
            \(q(layout.venvPython.path)) -m locwarpd >>"$LOG" 2>&1 &
          disown
        )
        log "spawn returned $?; sleeping 0.4s"
        sleep 0.4
        log "checking socket existence: $(ls -la \(q(layout.socketPath)) 2>&1)"
        log "===== privileged install done ====="
        """

        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "locwarp-elevate-\(UUID().uuidString).sh")
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
