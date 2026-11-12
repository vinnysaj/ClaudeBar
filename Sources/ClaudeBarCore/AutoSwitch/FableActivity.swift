import Foundation

/// Whether Claude Code on this machine is running Fable work, read from its
/// session logs. Usage figures can't tell: every machine signed into an account
/// moves its Fable usage, but only Fable work here gains from this machine's
/// login moving to an account with Fable left.
///
/// A running session counts while its latest request went to Fable, however
/// long it has sat idle since: its next prompt goes to Fable too, and has to
/// find Fable left on the login before it is sent, since a refusal at the limit
/// stops the session. Any other log, a subagent's or a session's that has
/// ended, counts for `recentWindow` after its latest request went to Fable.
enum FableActivity {
    /// How long a log that isn't a running session's counts after its latest
    /// request went to Fable. A subagent at work sends one every few moments;
    /// this spans a long tool call between them.
    static let recentWindow: TimeInterval = 15 * 60

    /// How much of a log's end is read for its latest request, widening while
    /// it holds none: the last lines can be one large tool result.
    private static let tailSizes: [Int64] = [64 << 10, 1 << 20, 8 << 20]

    struct Request: Equatable {
        let model: String
        let at: Date
    }

    static func isInUse(now: Date) -> Bool {
        let sessionOnFable = ClaudeCodeLogs.runningSessionLogs().contains { log in
            Self.latestRequest(in: log).map { Self.isFable($0.model) } ?? false
        }
        if sessionOnFable { return true }
        let since = now.addingTimeInterval(-Self.recentWindow)
        return ClaudeCodeLogs.files(modifiedSince: since).contains { log in
            guard let request = Self.latestRequest(in: log) else { return false }
            return request.at >= since && Self.isFable(request.model)
        }
    }

    /// Fable whatever version or provider prefix names it.
    static func isFable(_ model: String) -> Bool {
        model.lowercased().contains("fable")
    }

    /// The latest request among complete log lines, refused or answered: the
    /// model a session last asked for is the one its next prompt goes to. A
    /// session's log holds only its own requests; each subagent has a log of
    /// its own.
    ///
    /// Claude Code logs each request as `api-request` before sending it, then
    /// the reply under the model that wrote it, or for a refusal, at a usage
    /// limit say, a notice of its own marked `<synthetic>` that names no model.
    /// Logs written before requests were logged have only the replies.
    static func latestRequest(inLog log: Substring) -> Request? {
        for line in log.split(separator: "\n").reversed() {
            guard line.contains("\"model\""),
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let at = ClaudeCodeLogs.date(fromTimestamp: timestamp)
            else { continue }
            let model: String? = switch object["type"] as? String {
            case "api-request": (object["params"] as? [String: Any])?["model"] as? String
            case "assistant": (object["message"] as? [String: Any])?["model"] as? String
            default: nil
            }
            guard let model, model != "<synthetic>" else { continue }
            return Request(model: model, at: at)
        }
        return nil
    }

    private static func latestRequest(in file: ClaudeCodeLogs.File) -> Request? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        for tailSize in Self.tailSizes {
            let offset = max(0, file.size - tailSize)
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.readToEnd()
            else { return nil }
            var tail = Substring(String(decoding: data, as: UTF8.self))
            // Read from mid-file, the first line is cut short.
            if offset > 0 {
                guard let newline = tail.firstIndex(of: "\n") else { continue }
                tail = tail[tail.index(after: newline)...]
            }
            if let request = Self.latestRequest(inLog: tail) { return request }
            if offset == 0 { return nil }
        }
        return nil
    }
}
