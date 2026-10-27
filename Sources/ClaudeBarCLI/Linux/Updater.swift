#if os(Linux)
import ClaudeBarCore
import Foundation
import FoundationNetworking

/// Installs Linux releases over the running one: `claudebar` and, where it's
/// installed beside it, `claudebar-tray`.
actor Updater {
    static let shared = Updater()

    /// Whether the daemon installs updates by itself.
    static var installsAutomatically: Bool {
        get { Preferences.read(Bool.self, key: "installUpdatesAutomatically") ?? true }
        set { Preferences.write(newValue, key: "installUpdatesAutomatically") }
    }

    /// A daemon that keeps restarting shouldn't check on every start.
    private static let firstCheckDelay: Duration = .seconds(10 * 60)
    private static let checkInterval: Duration = .seconds(24 * 60 * 60)

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        return URLSession(configuration: configuration)
    }()

    private var isUpdating = false

    /// Installs the latest release when it's newer than this one.
    func update(progress: @Sendable (String) async -> Void) async throws -> UpdateOutcome {
        guard !self.isUpdating else { throw CLIFailure("An update is already running.") }
        self.isUpdating = true
        defer { self.isUpdating = false }

        await progress("Checking for updates...")
        let manifest = try await self.fetchManifest()
        guard manifest.build > AppVersion.build else {
            return UpdateOutcome(message: "ClaudeBar \(AppVersion.marketing) is up to date.", restarts: false)
        }
        let asset = try manifest.asset(for: Self.architecture)
        let directory = CurrentExecutable.url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw CLIFailure(
                "ClaudeBar is installed in \(directory.path), which you can't write to. Run the update with sudo, or reinstall into ~/.local/bin.")
        }

        await progress("Downloading ClaudeBar \(manifest.version)...")
        let archive = try await self.download(asset.url, "ClaudeBar \(manifest.version)")
        try ReleaseManifest.verify(archive, against: asset)

        await progress("Installing...")
        do {
            try self.install(archive, into: directory)
        } catch let error as CocoaError {
            throw CLIFailure("Installing into \(directory.path) failed: \(error.localizedDescription)")
        }
        return UpdateOutcome(message: "Updated to ClaudeBar \(manifest.version).", restarts: true)
    }

    /// Checks once a day, installing what it finds while automatic updates are on.
    func installAutomatically(restart: @Sendable () async -> Void) async {
        var delay = Self.firstCheckDelay
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            delay = Self.checkInterval
            guard Self.installsAutomatically else { continue }
            do {
                let outcome = try await self.update { step in
                    FileHandle.standardError.write(Data("[update] \(step)\n".utf8))
                }
                FileHandle.standardError.write(Data("[update] \(outcome.message)\n".utf8))
                if outcome.restarts {
                    await restart()
                }
            } catch {
                FileHandle.standardError.write(Data("[update] failed: \(error)\n".utf8))
            }
        }
    }

    /// Starts this process over on the binary now installed at its path, keeping
    /// its pid so systemd sees the same service.
    static func restart() -> Never {
        let arguments = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(CurrentExecutable.url.path, arguments)
        // Exec failed: exiting lets systemd start the new binary instead.
        FileHandle.standardError.write(Data("Restarting failed (errno \(errno)); exiting so the service restarts.\n".utf8))
        exit(EXIT_FAILURE)
    }

    private func fetchManifest() async throws -> ReleaseManifest {
        let data = try await self.download(ReleaseManifest.latestURL, "the latest release's details")
        do {
            return try JSONDecoder().decode(ReleaseManifest.self, from: data)
        } catch {
            throw CLIFailure("The latest release's details on GitHub couldn't be read.")
        }
    }

    /// Foundation's errors describe themselves as a dump of their user info on
    /// Linux, so a failed download is put in words here.
    private func download(_ url: URL, _ what: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(from: url)
        } catch let error as URLError {
            throw CLIFailure("Couldn't download \(what) from GitHub: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CLIFailure("Couldn't download \(what) from GitHub: it answered HTTP \(status).")
        }
        return data
    }

    /// Unpacks the archive beside the installed binaries, on the same disk, then
    /// renames each over the one it replaces: a running binary keeps its old
    /// file until it exits, and nothing ever sees half a binary.
    private func install(_ archive: Data, into directory: URL) throws {
        let staging = directory.appendingPathComponent(".claudebar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archiveFile = staging.appendingPathComponent("release.tar.gz")
        try archive.write(to: archiveFile)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        tar.arguments = ["tar", "-xzf", archiveFile.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw CLIFailure("Unpacking the release failed.") }

        for name in ["claudebar", "claudebar-tray"] {
            let unpacked = staging.appendingPathComponent(name)
            let installed = directory.appendingPathComponent(name)
            // The tray only replaces a tray that's there: servers go without.
            guard FileManager.default.fileExists(atPath: unpacked.path),
                  name == "claudebar" || FileManager.default.fileExists(atPath: installed.path)
            else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unpacked.path)
            guard rename(unpacked.path, installed.path) == 0 else {
                throw CLIFailure("Replacing \(installed.path) failed (errno \(errno)).")
            }
        }
    }

    private static var architecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
#endif
