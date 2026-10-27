import Foundation

/// The `claudebar` command the app bundles, and the link that puts it on the PATH.
enum CommandLineTool {
    /// Nil in builds without it, such as `swift build`.
    static var bundled: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claudebar")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Beside `claude`, where Claude Code's installer puts it.
    static var link: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/claudebar")
    }

    /// The link points at this copy of the app.
    static var isInstalled: Bool {
        guard let bundled = self.bundled,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: self.link.path)
        else { return false }
        return URL(fileURLWithPath: destination).standardizedFileURL == bundled.standardizedFileURL
    }

    static func install() throws {
        guard let bundled = self.bundled else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: self.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A link is an earlier install, maybe of an app since moved; anything
        // else is someone else's file.
        if (try? fileManager.destinationOfSymbolicLink(atPath: self.link.path)) != nil {
            try fileManager.removeItem(at: self.link)
        } else if fileManager.fileExists(atPath: self.link.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "Something other than ClaudeBar's claudebar is already at ~/.local/bin/claudebar.",
            ])
        }
        try fileManager.createSymbolicLink(at: self.link, withDestinationURL: bundled)
    }
}
