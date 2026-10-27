#if !os(macOS)
import Foundation

/// On Linux, Claude Code keeps its login in ~/.claude/.credentials.json, readable
/// by the user alone, and there may be no keyring to use instead: a server
/// reached over SSH has none unlocked. ClaudeBar keeps its roster the same way,
/// in a 0600 file inside its own 0700 directory.
enum CredentialStore {
    /// How messages name the place logins are kept.
    static let storeName = "its credentials file"

    private static var rosterFile: URL {
        AppPaths.support.appendingPathComponent("credentials.json")
    }

    static func readRoster() throws -> Data {
        try self.read(self.rosterFile)
    }

    static func writeRoster(_ data: Data) throws {
        do {
            try AppPaths.createPrivateDirectory(AppPaths.support)
        } catch {
            throw CredentialError.unexpected("securing \(AppPaths.support.path): \(error.localizedDescription)")
        }
        try self.write(data, to: self.rosterFile)
    }

    static func readLiveBlob() throws -> Data {
        try self.read(self.claudeCredentialsFile)
    }

    static func writeLiveBlob(_ data: Data) throws {
        try self.write(data, to: self.claudeCredentialsFile)
    }

    static func readSignInCredentials(home: URL) throws -> Data {
        try self.read(self.signInCredentialsFile(home: home))
    }

    /// The credentials are a file in the home, so they go with it.
    static func deleteSignInCredentials(home: URL) throws {}

    private static func read(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CredentialError.notFound }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw CredentialError.accessDenied }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CredentialError.unexpected("reading \(url.path): \(error.localizedDescription)")
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try AppPaths.writePrivateFile(data, to: url)
        } catch {
            throw CredentialError.unexpected("writing \(url.path): \(error.localizedDescription)")
        }
    }
}
#endif
