import Foundation

/// Standard file-system locations used by both the Mac app and the daemon.
public enum LocWarpPaths {
    public static var appSupportDir: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocWarp.Mac", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var cacheDir: URL {
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "LocWarp.Mac", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var logsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "LocWarp.Mac", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var socketPath: String {
        appSupportDir.appending(path: "locwarp.sock").path(percentEncoded: false)
    }
}
