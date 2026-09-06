import Foundation
import LociiGhostCore

/// Copy the developer-mode daemon source + venv out of the developer
/// checkout into `~/Library/Application Support`, where root scripts
/// launched via `osascript with administrator privileges` can actually
/// read it.
///
/// Without this step, the root daemon dies at `import site` because
/// even root can't read the checkout's `.venv/pyvenv.cfg` when it sits
/// under a TCC-protected folder (`~/Documents` and `~/Desktop` on
/// macOS 15+) without the user explicitly granting Full Disk Access.
/// Staging once to `~/Library/...` sidesteps the whole TCC dance — the
/// user-mode app has read access to the checkout, and the destination
/// isn't in any TCC-protected folder.
enum DaemonStaging {
    enum StagingError: LocalizedError {
        case sourceMissing(URL)
        case copyFailed(stderr: String, code: Int32)
        case rsyncMissing
        var errorDescription: String? {
            switch self {
            case .sourceMissing(let u):
                return "Daemon source not found at \(u.path). Check the project out under ~/Developer/LociiGhost, or point LOCIIGHOST_DAEMON_SOURCE at its Daemon directory."
            case .copyFailed(let s, let c):
                return "Daemon copy failed (\(c)): \(s)"
            case .rsyncMissing:
                return "rsync isn't on PATH; can't stage the daemon."
            }
        }
    }

    /// Where the staged daemon lives. Mirrors the layout of the
    /// developer checkout's `Daemon/` so paths inside the venv stay
    /// valid.
    static var stagedRoot: URL {
        LociiGhostPaths.appSupportDir
            .appending(path: "runtime/Daemon", directoryHint: .isDirectory)
    }

    /// The Python interpreter inside the staged venv. This is what
    /// `PrivilegedDaemonInstaller` and `DaemonLifecycle` actually
    /// invoke — never the original inside the checkout.
    static var stagedPython: URL {
        stagedRoot.appending(path: ".venv/bin/python")
    }

    /// PYTHONPATH to point at the staged source tree.
    static var stagedPYTHONPATH: URL { stagedRoot }

    /// Where we look for the developer checkout, in priority order.
    ///
    /// `~/Documents` stays on the list so existing checkouts keep
    /// working, but it is deliberately no longer first. It is both
    /// TCC-protected and — when "Desktop & Documents" iCloud sync is
    /// on — a folder whose file contents get evicted: a venv there
    /// produces reads that either stall for seconds per file or
    /// succeed while returning zero bytes, which looks like corrupt
    /// bytecode rather than a storage problem.
    static var sourceCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "Developer/LociiGhost/Daemon",
            "Documents/LociiGhost/Daemon",
        ].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// Source location — the developer checkout we copy *from*. The
    /// user's app process can read it; root scripts spawned via
    /// osascript may not, which is the whole reason staging exists.
    ///
    /// `LOCIIGHOST_DAEMON_SOURCE` overrides the search outright, so a
    /// checkout anywhere can be pointed at without a rebuild. When
    /// nothing is found we return the first candidate so the
    /// `sourceMissing` error names a useful path.
    static var sourceRoot: URL {
        if let override = ProcessInfo.processInfo.environment["LOCIIGHOST_DAEMON_SOURCE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let fm = FileManager.default
        let candidates = sourceCandidates
        return candidates.first {
            fm.fileExists(atPath: $0.path(percentEncoded: false))
        } ?? candidates[0]
    }

    /// True when the .app ships a self-contained PyInstaller daemon
    /// at `Contents/Resources/lociighostd/lociighostd`. End-user
    /// distributions (the DMG from Google Drive) include this; dev
    /// builds that skip `Daemon/dist/` during package-app.sh don't.
    ///
    /// `.absoluteURL` matters: `Bundle.main.resourceURL` is a relative
    /// URL with a base (the .app's URL), and modern
    /// `URL.path(percentEncoded:)` doesn't resolve that — see the long
    /// comment in `DaemonLifecycle.resolveExecutable()` for the full
    /// diagnosis. The deprecated `.path` getter (used here in v1.10.4
    /// and earlier) happened to resolve correctly, which is why
    /// `hasBundledDaemon` returned true while `resolveExecutable()`
    /// returned `daemonNotFound` on the same .app. v1.10.5 makes both
    /// callsites use the same `.absoluteURL.path(percentEncoded: false)`
    /// idiom so they can never disagree again.
    static var hasBundledDaemon: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let bundled = resources
            .appending(path: "lociighostd")
            .appending(path: "lociighostd")
            .absoluteURL
        return FileManager.default.isExecutableFile(atPath: bundled.path(percentEncoded: false))
    }

    /// Make sure a usable copy of the daemon exists at `stagedRoot`.
    /// Re-stages if the source's `__init__.py` is newer than the
    /// staged one's, so day-to-day daemon edits don't require manual
    /// resync.
    static func ensureStaged() async throws {
        // End-user path: when the .app ships its own daemon inside
        // Contents/Resources/, neither DaemonLifecycle nor
        // PrivilegedDaemonInstaller will go anywhere near the staged
        // tree. Calling ensureStaged() in that case would crash with
        // "Daemon source not found" on machines that — correctly —
        // don't have the LociiGhost repo cloned at all.
        // Short-circuit before touching the filesystem so AppState
        // can blindly call this on every daemon boot.
        if hasBundledDaemon {
            return
        }

        let source = sourceRoot
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw StagingError.sourceMissing(source)
        }

        if !needsRestage(source: source, staged: stagedRoot) {
            return
        }

        try FileManager.default.createDirectory(
            at: stagedRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let rsyncPath = "/usr/bin/rsync"
        guard FileManager.default.isExecutableFile(atPath: rsyncPath) else {
            throw StagingError.rsyncMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsyncPath)
        process.arguments = [
            "-a",                                    // archive: preserve symlinks, perms, timestamps
            "--delete",                              // mirror exactly — drops files removed in source
            "--exclude", "__pycache__",
            "--exclude", "*.pyc",
            "--exclude", ".pytest_cache",
            "--exclude", "build/",
            "--exclude", "dist/",
            source.path + "/",                       // trailing slash → copy contents, not dir itself
            stagedRoot.path + "/",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        await Task.detached { process.waitUntilExit() }.value

        if process.terminationStatus != 0 {
            let raw = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw StagingError.copyFailed(
                stderr: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                code: process.terminationStatus
            )
        }

        // The editable-install path files inside the venv still point
        // at the source location after copy. Rewrite them so `import
        // lociighostd` resolves to the staged tree, not back into the
        // checkout.
        rewriteEditablePathFiles(
            stagedRoot: stagedRoot,
            sourcePath: source.path,
            newPath: stagedRoot.path
        )

        // Wipe every `__pycache__/` left over from previous runs.
        // rsync was told to skip them so the cache wouldn't bloat the
        // copy — but the side effect is that stale `.pyc` files
        // matching old `.py` mtimes survive across re-stages, and on
        // some Python builds the cached bytecode is used in preference
        // to a freshly-stamped source file. That's how a "the file on
        // disk has the new fix but the daemon keeps running the old
        // code" mystery happens. Cleanest cure: nuke the caches.
        purgePycache(under: stagedRoot)
    }

    private static func purgePycache(under root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__pycache__" {
                try? FileManager.default.removeItem(at: url)
                enumerator.skipDescendants()
            }
        }
    }

    // MARK: -

    private static func needsRestage(source: URL, staged: URL) -> Bool {
        let stagedPython = staged.appending(path: ".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: stagedPython.path) else {
            return true
        }

        // The earlier proxy of "is `__init__.py` newer than the staged
        // copy" silently missed daemon edits to any other file
        // (device_manager, handlers, etc.). Walk the whole source tree
        // and re-stage if *any* `.py` file is newer than the staged
        // counterpart. rsync skips unchanged files anyway, so this is
        // O(seconds) at worst.
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else {
            return true
        }
        let sourcePathLen = source.path.count
        for case let url as URL in enumerator {
            guard url.pathExtension == "py" else { continue }
            // Skip anything inside the venv — that's third-party code,
            // it doesn't track our edits.
            if url.path.contains("/.venv/") { continue }
            let relativePath = String(url.path.dropFirst(sourcePathLen + 1))
            let stagedFile = staged.appending(path: relativePath)
            guard
                let s = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else { continue }
            guard
                let t = (try? stagedFile.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else {
                return true
            }
            if s > t {
                return true
            }
        }
        return false
    }

    /// Walk every `*.pth` and `*.dist-info/RECORD` in the staged venv's
    /// site-packages and rewrite any embedded reference to the
    /// `~/Documents/...` source path so it points at the staged copy.
    /// Without this, `pip install -e .` artifacts make Python look for
    /// modules back in `~/Documents`, defeating the whole stage.
    private static func rewriteEditablePathFiles(
        stagedRoot: URL,
        sourcePath: String,
        newPath: String
    ) {
        let venvLib = stagedRoot.appending(path: ".venv/lib", directoryHint: .isDirectory)
        guard let pyDirs = try? FileManager.default.contentsOfDirectory(atPath: venvLib.path) else {
            return
        }
        for pyDir in pyDirs where pyDir.hasPrefix("python") {
            let sitePackages = venvLib.appending(path: pyDir).appending(path: "site-packages")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: sitePackages,
                includingPropertiesForKeys: nil
            ) else { continue }
            for entry in entries {
                let ext = entry.pathExtension
                guard ext == "pth" else { continue }
                guard let content = try? String(contentsOf: entry, encoding: .utf8) else { continue }
                if content.contains(sourcePath) {
                    let updated = content.replacingOccurrences(of: sourcePath, with: newPath)
                    try? updated.write(to: entry, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
