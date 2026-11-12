import Foundation
import Testing
@testable import ClaudeBarCore

/// Log lines as Claude Code writes them, cut down to the fields that matter.
private func request(_ model: String, at timestamp: String) -> String {
    #"{"type":"api-request","timestamp":"\#(timestamp)","params":{"model":"\#(model)","max_tokens":128000}}"#
}

private func reply(_ model: String, at timestamp: String) -> String {
    #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"model":"\#(model)","role":"assistant"}}"#
}

private func prompt(at timestamp: String) -> String {
    #"{"type":"user","timestamp":"\#(timestamp)","message":{"role":"user","content":"go on"}}"#
}

@Suite("Fable activity")
struct FableActivityTests {
    @Test(
        "A session's latest request, refused or answered, names the model its next prompt goes to",
        arguments: [
            // Refused at the Fable limit: the notice names no model, the request does.
            (log: [
                request("claude-opus-5-5", at: "2026-11-12T19:00:00.000Z"),
                reply("claude-opus-5-5", at: "2026-11-12T19:00:02.000Z"),
                prompt(at: "2026-11-12T19:05:00.000Z"),
                request("claude-fable-5-2", at: "2026-11-12T19:05:37.853Z"),
                reply("<synthetic>", at: "2026-11-12T19:05:38.159Z"),
            ], model: "claude-fable-5-2", at: "2026-11-12T19:05:37.853Z"),
            // Switched off Fable: the earlier Fable replies no longer count.
            ([
                request("claude-fable-5-2", at: "2026-11-12T19:00:00.000Z"),
                reply("claude-fable-5-2", at: "2026-11-12T19:00:02.000Z"),
                request("claude-opus-5-5", at: "2026-11-12T19:01:00.000Z"),
                reply("claude-opus-5-5", at: "2026-11-12T19:01:03.000Z"),
                prompt(at: "2026-11-12T19:02:00.000Z"),
            ], "claude-opus-5-5", "2026-11-12T19:01:03.000Z"),
            // A log from before requests were logged has only the replies.
            ([
                reply("claude-fable-5-1", at: "2026-11-12T19:00:02.000Z"),
                prompt(at: "2026-11-12T19:02:00.000Z"),
            ], "claude-fable-5-1", "2026-11-12T19:00:02.000Z"),
        ])
    func latestRequestNamesTheNextModel(log: [String], model: String, at timestamp: String) throws {
        let request = FableActivity.latestRequest(inLog: Substring(log.joined(separator: "\n")))
        let expectedAt = try Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        #expect(request == FableActivity.Request(model: model, at: expectedAt))
    }
}
