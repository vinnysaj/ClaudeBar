import Foundation

public struct ScanProgress: Sendable, Codable {
    public let scannedFiles: Int
    public let totalFiles: Int
    public let isComplete: Bool

    public var fraction: Double {
        guard self.totalFiles > 0 else { return 0 }
        return Double(self.scannedFiles) / Double(self.totalFiles)
    }
}

final class CostScanner: Sendable {
    static let shared = CostScanner()

    private let progressContinuation: AsyncStream<ScanProgress>.Continuation
    let progressStream: AsyncStream<ScanProgress>

    private init() {
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()
        self.progressStream = stream
        self.progressContinuation = continuation
    }

    private func reportProgress(scanned: Int, total: Int, isComplete: Bool) {
        self.progressContinuation.yield(ScanProgress(scannedFiles: scanned, totalFiles: total, isComplete: isComplete))
    }

    /// Walks the Claude Code logs and totals cost for today and the last 30 days,
    /// with the last week hour by hour. Rates come from `pricing`; models it
    /// doesn't cover land in the snapshot's `unpricedModels` with their tokens
    /// counted but no cost attributed.
    func scan(pricing: PricingTable) -> CostSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let windowStart = CostSnapshot.windowStart(now: now, calendar: calendar)

        var cache = CostCache.load(version: CostCache.version(pricing: pricing, timeZone: calendar.timeZone))
        let allFiles = ClaudeCodeLogs.files(modifiedSince: windowStart)

        let totalFiles = allFiles.count
        self.reportProgress(scanned: 0, total: totalFiles, isComplete: false)

        var hoursByStart: [Date: HourlyUsage] = [:]
        var seenMessageKeys: Set<String> = []
        var touchedPaths: Set<String> = []

        for (index, file) in allFiles.enumerated() {
            let path = file.url.path
            let mtimeMs = Int64(file.modifiedAt.timeIntervalSince1970 * 1000)
            touchedPaths.insert(path)

            let fileHours: [HourlyUsage]
            let wasCached: Bool
            if let cached = cache.files[path],
               cached.mtimeMs == mtimeMs,
               cached.size == file.size
            {
                fileHours = cached.hours
                wasCached = true
            } else {
                fileHours = Self.parseFile(
                    url: file.url,
                    pricing: pricing,
                    since: windowStart,
                    calendar: calendar,
                    seenKeys: &seenMessageKeys)
                cache.files[path] = CachedFile(mtimeMs: mtimeMs, size: file.size, hours: fileHours)
                wasCached = false
            }

            for hour in fileHours {
                hoursByStart[hour.start, default: HourlyUsage(start: hour.start, cost: 0, tokens: 0, unpricedModels: [])]
                    .add(hour)
            }

            // Cached files go by quickly, so they report less often and leave
            // the cache as it was.
            if (index + 1) % (wasCached ? 200 : 50) == 0 || index == totalFiles - 1 {
                self.reportProgress(scanned: index + 1, total: totalFiles, isComplete: false)
                if !wasCached {
                    cache.save()
                }
            }
        }

        for path in cache.files.keys where !touchedPaths.contains(path) {
            cache.files.removeValue(forKey: path)
        }

        cache.save()
        self.reportProgress(scanned: totalFiles, total: totalFiles, isComplete: true)

        return CostSnapshot(summarizing: hoursByStart.values, now: now, calendar: calendar)
    }

    // MARK: - File parsing

    /// The file's usage per local clock hour, from `since` on.
    private static func parseFile(
        url: URL,
        pricing: PricingTable,
        since: Date,
        calendar: Calendar,
        seenKeys: inout Set<String>) -> [HourlyUsage]
    {
        var hours: [Date: HourlyUsage] = [:]

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8)
        else { return [] }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"") else { continue }
            guard line.contains("\"usage\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "assistant"
            else { continue }

            guard let timestamp = obj["timestamp"] as? String,
                  let loggedAt = ClaudeCodeLogs.date(fromTimestamp: timestamp),
                  loggedAt >= since,
                  let hourStart = calendar.dateInterval(of: .hour, for: loggedAt)?.start
            else { continue }

            guard let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            // Assistant messages Claude Code writes itself (error notices and the
            // like) carry this in place of a model. Nothing reached the API.
            if model == "<synthetic>" { continue }

            let messageId = message["id"] as? String
            let requestId = obj["requestId"] as? String
            if let messageId, let requestId {
                let key = "\(messageId):\(requestId)"
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
            }

            let inputTokens = Self.intValue(usage["input_tokens"])
            let outputTokens = Self.intValue(usage["output_tokens"])
            let cacheReadTokens = Self.intValue(usage["cache_read_input_tokens"])
            let cacheCreateTokens = Self.intValue(usage["cache_creation_input_tokens"])
            // Cache creation splits into 5-minute (1.25x) and 1-hour (2x) TTLs at different rates.
            // Tokens not explicitly tagged 1-hour (incl. older logs lacking the breakdown) bill at the 5m rate.
            let cacheWrite1hTokens = Self.intValue((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
            let cacheWrite5mTokens = max(0, cacheCreateTokens - cacheWrite1hTokens)
            let lineTokens = inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens
            if lineTokens == 0 { continue }

            // Fast mode is recorded on usage.speed, not in the model string.
            let isFast = (usage["speed"] as? String) == "fast"

            var hour = hours[hourStart] ?? HourlyUsage(start: hourStart, cost: 0, tokens: 0, unpricedModels: [])
            hour.tokens += lineTokens

            if let modelPricing = pricing.pricing(for: model, isFast: isFast) {
                hour.cost += Self.computeCost(
                    pricing: modelPricing,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWrite5mTokens: cacheWrite5mTokens,
                    cacheWrite1hTokens: cacheWrite1hTokens)
            } else {
                // Count the tokens but attribute no cost, and name the model so the
                // UI can say the total is short rather than passing it off as whole.
                let name = PricingTable.normalizeModelName(model)
                if !hour.unpricedModels.contains(name) {
                    hour.unpricedModels.append(name)
                }
            }

            hours[hourStart] = hour
        }

        return hours.values.sorted { $0.start < $1.start }
    }

    // MARK: - Pricing

    private static func computeCost(
        pricing: ModelPricing,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWrite5mTokens: Int,
        cacheWrite1hTokens: Int) -> Double
    {
        let perToken = 1.0 / 1_000_000
        return Double(inputTokens) * pricing.input * perToken
            + Double(outputTokens) * pricing.output * perToken
            + Double(cacheWrite5mTokens) * pricing.cacheWrite5m * perToken
            + Double(cacheWrite1hTokens) * pricing.cacheWrite1h * perToken
            + Double(cacheReadTokens) * pricing.cacheRead * perToken
    }

    // MARK: - Helpers

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }
}

// MARK: - Cache types

struct CachedFile: Codable {
    let mtimeMs: Int64
    let size: Int64
    let hours: [HourlyUsage]
}

struct CostCache: Codable {
    /// Bump when the shape of what's cached changes, so an old file is discarded
    /// rather than decoded into the new types.
    private static let schemaVersion = 4

    /// Identifies the rates the cached costs were computed at and the time zone
    /// their hours were cut in. Rates arriving over the network means this can't
    /// be a constant we remember to bump: it is derived from the pricing itself,
    /// so any change invalidates the cache.
    static func version(pricing: PricingTable, timeZone: TimeZone) -> String {
        "\(Self.schemaVersion):\(timeZone.identifier):\(pricing.version)"
    }

    var version: String
    var files: [String: CachedFile] = [:]

    private static var cacheURL: URL {
        AppPaths.caches.appendingPathComponent("cost-cache.json")
    }

    static func load(version: String) -> CostCache {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let decoded = try? JSONDecoder().decode(CostCache.self, from: data),
              decoded.version == version
        else { return CostCache(version: version) }
        return decoded
    }

    func save() {
        let url = Self.cacheURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
