import Foundation

/// The session logs Claude Code writes on this machine: a JSONL file per
/// session, and one per subagent in a folder beside it, each only ever
/// appended to.
enum ClaudeCodeLogs {
    struct File: Sendable {
        let url: URL
        let size: Int64
        let modifiedAt: Date
    }

    /// Where Claude Code keeps its files: `~/.claude`, or `~/.config/claude`
    /// where it follows the XDG layout.
    private static var configDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".config/claude"), home.appendingPathComponent(".claude")]
    }

    private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

    /// Every log written to at or after `since`. A log only grows, so one last
    /// written before then holds nothing from after it. Most logs on disk are
    /// that old, and skipping them unread is what keeps a scan quick.
    static func files(modifiedSince since: Date) -> [File] {
        var files: [File] = []
        for directory in Self.configDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory.appendingPathComponent("projects"),
                includingPropertiesForKeys: Array(Self.fileKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                guard let file = Self.file(at: url), file.modifiedAt >= since else { continue }
                files.append(file)
            }
        }
        return files
    }

    /// The logs of the sessions running now. While a session runs, Claude Code
    /// keeps an entry for it in `sessions/` naming its process and the session
    /// it's on, whose log sits in the folder for its working directory.
    static func runningSessionLogs() -> [File] {
        var logs: [File] = []
        for directory in Self.configDirectories {
            let registry = directory.appendingPathComponent("sessions")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: registry, includingPropertiesForKeys: nil)
            else { continue }
            let sessionIds = entries
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> String? in
                    guard let data = try? Data(contentsOf: url),
                          let entry = try? JSONDecoder().decode(SessionEntry.self, from: data),
                          Self.isRunning(pid: entry.pid)
                    else { return nil }
                    return entry.sessionId
                }
            guard !sessionIds.isEmpty else { continue }
            // Found by name rather than by rebuilding the folder's name from the
            // working directory, which Claude Code shortens past a length.
            let projects = (try? FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("projects"), includingPropertiesForKeys: nil)) ?? []
            for sessionId in sessionIds {
                let log = projects.lazy
                    .compactMap { Self.file(at: $0.appendingPathComponent("\(sessionId).jsonl")) }
                    .first
                if let log { logs.append(log) }
            }
        }
        return logs
    }

    private struct SessionEntry: Decodable {
        let pid: Int32
        let sessionId: String
    }

    private static func isRunning(pid: Int32) -> Bool {
        // A pid of 0 or below would ask after a whole process group.
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static func file(at url: URL) -> File? {
        guard let values = try? url.resourceValues(forKeys: Self.fileKeys),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0,
              let modifiedAt = values.contentModificationDate
        else { return nil }
        return File(url: url, size: Int64(size), modifiedAt: modifiedAt)
    }

    private static let timestampWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Log timestamps are ISO 8601 in UTC, normally with milliseconds.
    static func date(fromTimestamp timestamp: String) -> Date? {
        if let date = try? Date(timestamp, strategy: Self.timestampWithFraction) {
            return date
        }
        return try? Date(timestamp, strategy: .iso8601)
    }
}
