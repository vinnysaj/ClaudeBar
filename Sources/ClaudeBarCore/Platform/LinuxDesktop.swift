#if os(Linux)
import Foundation

/// Where this process's binary is installed. After an update has replaced it,
/// the kernel still names the old file, marked deleted; the path is the same.
public enum CurrentExecutable {
    public static var url: URL {
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
            ?? CommandLine.arguments[0]
        let deletedMarker = " (deleted)"
        let path = target.hasSuffix(deletedMarker) ? String(target.dropLast(deletedMarker.count)) : target
        return URL(fileURLWithPath: path)
    }

    /// The tray, which ships in the same archive and installs beside `claudebar`.
    public static var tray: URL {
        self.url.deletingLastPathComponent().appendingPathComponent("claudebar-tray")
    }
}

/// The XDG autostart entry that opens the tray when the desktop session starts.
public enum TrayAutostart {
    public static var entry: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return configHome.appendingPathComponent("autostart/claudebar-tray.desktop")
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: self.entry.path)
    }

    public static func enable(tray: URL) throws {
        let contents = """
            [Desktop Entry]
            Type=Application
            Name=ClaudeBar
            Comment=Claude Code usage across accounts
            Exec="\(tray.path)"
            NoDisplay=true
            X-GNOME-Autostart-enabled=true

            """
        try FileManager.default.createDirectory(
            at: self.entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: self.entry, options: .atomic)
    }

    public static func disable() throws {
        guard self.isEnabled else { return }
        try FileManager.default.removeItem(at: self.entry)
    }
}
#endif
