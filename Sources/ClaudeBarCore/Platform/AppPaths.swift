import Foundation

/// Where ClaudeBar keeps its files: Application Support and Caches on the Mac,
/// and their XDG counterparts (~/.local/share, ~/.cache) on Linux.
public enum AppPaths {
    /// Accounts, history, pricing and settings: what can't be refetched.
    public static var support: URL {
        self.directory(.applicationSupportDirectory)
    }

    /// What can be rebuilt: the usage and cost caches.
    public static var caches: URL {
        self.directory(.cachesDirectory)
    }

    /// Where the running app or daemon listens for the CLI and the tray.
    public static var controlSocket: URL {
        self.support.appendingPathComponent("control.sock")
    }

    private static func directory(_ kind: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: kind, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ClaudeBar", isDirectory: true)
    }

    /// Creates `directory`, or narrows an existing one, to be readable by the user
    /// alone. ClaudeBar's support directory holds the socket that drives it, and
    /// on Linux its stored logins, in plain files as Claude Code keeps its own.
    public static func createPrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Writes `data` to `url` atomically, readable and writable by the user alone
    /// from the moment it lands.
    public static func writePrivateFile(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw Self.posixError() }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
