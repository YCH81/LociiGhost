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
        // v1.15.2 audit (X1/X14): the daemon executable is either
        // inside /Applications/LociiGhost.app (writable by any admin
        // user WITHOUT re-authenticating, since /Applications is
        // drwxrwxr-x root:admin) or, in dev mode, under
        // ~/Library/Application Support, which is writable by the
        // user outright. Either way, whatever sits at that path gets
        // executed as root the next time the user authenticates —
        // turning one legitimate admin prompt into arbitrary root
        // code execution. The script below now refuses to exec
        // anything that a non-root user could have modified, and
        // verifies the code signature when the binary carries one.
        // Rather than hardcode a Team ID (this project takes its
        // signing identity from the environment at build time), we
        // require the daemon to be signed by whoever signed the app
        // that is asking to launch it. An unsigned app is a dev build
        // and gets a warning instead of a refusal.
        let appBundlePath = Bundle.main.bundleURL.path
        let body = """
        #!/bin/bash
        # v1.15.2 audit (X1, second pass): pin PATH before anything
        # else. This script runs as root but inherits the invoking
        # user's environment, and every command below — stat, pkill,
        # pgrep, awk, date, rm, mkdir, sleep, codesign — was being
        # resolved through it. A writable directory early in the user's
        # PATH would have shadowed any one of them and run as root,
        # which is precisely the escalation the ownership checks below
        # exist to prevent. Found by extracting this script and
        # exercising it, not by reading it.
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        LOG=\(q(layout.logFile.path))
        # v1.15.2 audit (X3): the log lives under the user's own
        # ~/Library/Logs, and this script appends to it as root. A
        # symlink planted there — at /etc/sudoers.d/x, say, or a
        # LaunchDaemon plist — would have been followed, and the log
        # format leaves attacker-influenceable text on each line.
        # Refuse to write through a symlink, and make sure the file is
        # ours before appending to it.
        if [ -h "$LOG" ]; then rm -f "$LOG"; fi
        if [ -e "$LOG" ]; then
          LOGOWNER=$(stat -f '%u' "$LOG" 2>/dev/null || echo -1)
          if [ "$LOGOWNER" != "0" ] && [ "$LOGOWNER" != "\(layout.uid)" ]; then
            LOG=/dev/null
          fi
        fi
        log() { printf '[%s] %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }
        log "===== privileged install start ====="
        log "uid=$(id -u) euid=$(id -un) home=$HOME"
        # Single-quoted: this is the one interpolation in the script
        # that put a filesystem path inside a DOUBLE-quoted shell
        # string, so a path containing $(…), a backtick or $VAR would
        # have been expanded — by a root shell (v1.15.2 audit X1,
        # second pass). Every other interpolation here is either a
        # numeric uid/gid, a literal, or already q()-escaped.
        log \(q("daemon: " + layout.daemonExecutable.path))
        mkdir -p \(q(layout.socketDir.path)) \(q(layout.logFile.deletingLastPathComponent().path)) || log "mkdir failed: $?"
        log "killing any prior lociighostd..."
        # Match on the basename `lociighostd` — covers both the
        # bundled PyInstaller binary (whose argv[0] ends in
        # /lociighostd) and the Python dev-mode invocation (which
        # shows up as `Python -m lociighostd` in ps -f, matching via
        # the `-m` substring).
        # First TERM (graceful), short pause, then KILL.
        # v1.15.2 audit (X13): the unscoped `pkill -f` ran as root and
        # matched command lines across EVERY user on the machine — a
        # `tail -f .../lociighostd.log` in another account was fair
        # game. Our daemon only ever runs as root or as the invoking
        # user, so those are the only two scopes we need.
        pkill -TERM -u 0 -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched TERM (root)"
        pkill -TERM -u \(layout.uid) -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched TERM (uid=\(layout.uid))"
        sleep 0.5
        pkill -KILL -u 0 -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched KILL (root)"
        pkill -KILL -u \(layout.uid) -f '\(pkillPattern)' >>"$LOG" 2>&1 \\
          || log "no daemons matched KILL (uid=\(layout.uid))"
        sleep 0.2
        log "post-kill survivors: $(pgrep -fl '\(pkillPattern)' || echo none)"
        log "removing stale socket..."
        rm -f \(q(layout.socketPath)) >>"$LOG" 2>&1 || true

        # ---- refuse to run anything a non-root user could have edited
        #
        # Exit codes, so the log identifies the failing check exactly:
        #   90 missing / not executable   94 signature verify failed
        #   91 path is a symlink          95 signing team != app's team
        #   92 group/other writable       96 mode unreadable
        #   93 unexpected owner           97 owner unreadable
        DAEMON=\(q(layout.daemonExecutable.path))
        if [ ! -x "$DAEMON" ]; then
          log "FATAL: daemon missing or not executable: $DAEMON"; exit 90
        fi
        # -h catches a symlink swapped in for the real binary.
        if [ -h "$DAEMON" ]; then
          log "FATAL: daemon path is a symlink: $DAEMON"; exit 91
        fi
        PERM=$(stat -f '%Lp' "$DAEMON" 2>/dev/null)
        OWNER=$(stat -f '%u' "$DAEMON" 2>/dev/null)
        # Fail closed, but say WHY. Feeding an empty or malformed value
        # to $(( 8#$PERM )) is a bash error that leaves the comparison
        # undefined, and reporting "mode 777" or "uid -1" for what was
        # really a stat failure sends whoever reads the log looking for
        # a permissions problem that doesn't exist.
        case "$PERM" in
          [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
          *) log "FATAL: could not read the mode of $DAEMON (stat gave '$PERM')"
             exit 96 ;;
        esac
        case "$OWNER" in
          ''|*[!0-9]*) log "FATAL: could not read the owner of $DAEMON (stat gave '$OWNER')"
                       exit 97 ;;
        esac
        # group- or other-writable means someone who is not root can
        # change what root executes.
        if [ $(( 8#$PERM & 8#022 )) -ne 0 ]; then
          log "FATAL: daemon is group/other writable (mode $PERM): $DAEMON"
          exit 92
        fi
        if [ "$OWNER" != "0" ] && [ "$OWNER" != "\(layout.uid)" ]; then
          log "FATAL: daemon owned by uid $OWNER, expected 0 or \(layout.uid)"
          exit 93
        fi
        # Signature check. The daemon must be signed by whoever signed
        # the app requesting this launch. A dev-mode Python venv isn't
        # signed at all, so unsigned-on-both-sides is a warning rather
        # than a refusal; a mismatch is a hard stop.
        team_of() {
          /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 \\
            | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2}'
        }
        APP_TEAM=$(team_of \(q(appBundlePath)))
        DAEMON_TEAM=$(team_of "$DAEMON")
        if [ -n "$APP_TEAM" ] && [ "$APP_TEAM" != "not set" ]; then
          if ! /usr/bin/codesign --verify --strict "$DAEMON" >>"$LOG" 2>&1; then
            log "FATAL: $DAEMON fails signature verification"
            exit 94
          fi
          if [ "$DAEMON_TEAM" != "$APP_TEAM" ]; then
            log "FATAL: daemon team '$DAEMON_TEAM' != app team '$APP_TEAM'"
            exit 95
          fi
          log "codesign: OK (team $APP_TEAM)"
        else
          log "codesign: app unsigned (dev build) - skipping team check"
        fi

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

        // v1.15.2 audit (X2): this used to drop a 0755 script straight
        // into $TMPDIR and hand osascript its path. Between the write
        // and the moment root actually read it — a window that spans
        // the user typing a password or reaching for Touch ID — any
        // process running as this user could overwrite the file, and
        // `ls $TMPDIR/lociighost-elevate-*.sh` made it trivial to
        // find. The replacement then ran as root.
        //
        // The script now lives in a 0700 directory created with
        // withIntermediateDirectories:false (so it fails rather than
        // reusing an attacker-planted directory) and is itself 0600 —
        // only root, which is who reads it, needs access at all.
        //
        // 0600 means NOT EXECUTABLE, root included: exec needs an x
        // bit somewhere in the mode, and root's read/write override
        // doesn't extend to it. `runAsAdmin` therefore has to feed
        // this file to an interpreter rather than exec it. That
        // pairing is load-bearing — see the matching note there
        // before changing either half.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lociighost-elevate-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let tmp = dir.appending(path: "bootstrap.sh")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tmp.path
        )
        return tmp
    }

    // MARK: - osascript bridge

    private static func runAsAdmin(scriptPath: URL) async throws {
        // `quoted form of` is AppleScript's own POSIX-escape for paths,
        // so we don't have to backslash-escape anything ourselves.
        //
        // The explicit `/bin/sh` is required, not stylistic. The
        // bootstrap file is written 0600 (see the note at its write
        // site), and a file with no x bit cannot be executed even by
        // root. Handing the bare path to `do shell script` makes the
        // shell try to exec it, which fails with
        //
        //     /bin/sh: …/bootstrap.sh: Permission denied (126)
        //
        // after the user has already authenticated — so the symptom
        // is "Admin install failed" with a password prompt that
        // looked like it worked. That is exactly what the v1.15.2
        // audit shipped: it tightened the mode from 0755 to 0600 and
        // left the invocation execing the path. Passing the script to
        // an interpreter keeps the tightened mode AND works.
        let appleScript = """
        do shell script ("/bin/sh " & quoted form of "\(scriptPath.path)") with administrator privileges
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
