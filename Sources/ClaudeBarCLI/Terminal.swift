import Foundation

/// Where claudebar's output goes and who reads it.
enum Terminal {
    /// The user is at another machine, over SSH, or this one has no screen: a
    /// browser here can't be used, and the local clipboard isn't theirs.
    static var isRemote: Bool {
        let environment = ProcessInfo.processInfo.environment
        if ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"].contains(where: { environment[$0] != nil }) {
            return true
        }
        #if os(Linux)
        return environment["DISPLAY"] == nil && environment["WAYLAND_DISPLAY"] == nil
        #else
        return false
        #endif
    }

    /// Colors when printing to a terminal, unless NO_COLOR says otherwise.
    static let usesColor: Bool = {
        isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }()

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// Lines typed on standard input, read on a thread of their own so waiting
    /// for one blocks nothing else.
    ///
    /// The thread reads the file descriptor, not stdio's stdin: a thread waiting
    /// in `readLine` holds stdin's lock, and musl's `exit` takes every stream's
    /// lock, so the static Linux build would never exit while one waited.
    static func inputLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread {
                var pending: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(STDIN_FILENO, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    pending += buffer[..<count]
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
                        pending.removeSubrange(...newline)
                    }
                }
                if !pending.isEmpty {
                    continuation.yield(String(decoding: pending, as: UTF8.self))
                }
                continuation.finish()
            }.start()
        }
    }

    /// Asks a yes-or-no question; anything but yes is no.
    static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        fflush(nil)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

/// ANSI styling, applied only when `Terminal.usesColor`.
enum Style: String {
    case bold = "1"
    case dim = "2"
    case red = "31"
    case green = "32"
    case yellow = "33"

    func callAsFunction(_ text: String) -> String {
        guard Terminal.usesColor, !text.isEmpty else { return text }
        return "\u{1B}[\(self.rawValue)m\(text)\u{1B}[0m"
    }
}

/// Puts text on the clipboard of whoever's at the keyboard.
enum Clipboard {
    enum Result {
        /// A clipboard tool on this machine took it.
        case copied
        /// Sent to the terminal to put on its machine's clipboard (OSC 52).
        /// Terminals that don't support it ignore it, so this can't be confirmed.
        case sentToTerminal
        case failed
    }

    static func copy(_ text: String) -> Result {
        if !Terminal.isRemote, self.copyWithLocalTool(text) {
            return .copied
        }
        return self.sendToTerminal(text) ? .sentToTerminal : .failed
    }

    /// The OSC 52 escape, written straight to the terminal so it works with
    /// output redirected. Over SSH it reaches the clipboard of the machine the
    /// terminal runs on. tmux passes it on with `set -g set-clipboard on`.
    private static func sendToTerminal(_ text: String) -> Bool {
        guard let terminal = FileHandle(forWritingAtPath: "/dev/tty") else { return false }
        let sequence = "\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}"
        do {
            try terminal.write(contentsOf: Data(sequence.utf8))
            try terminal.close()
            return true
        } catch {
            return false
        }
    }

    private static func copyWithLocalTool(_ text: String) -> Bool {
        for (tool, arguments) in self.localTools {
            guard let executable = self.find(tool) else { continue }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                continue
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        }
        return false
    }

    private static var localTools: [(String, [String])] {
        #if os(macOS)
        return [("pbcopy", [])]
        #else
        let environment = ProcessInfo.processInfo.environment
        var tools: [(String, [String])] = []
        if environment["WAYLAND_DISPLAY"] != nil {
            tools.append(("wl-copy", []))
        }
        if environment["DISPLAY"] != nil {
            tools.append(("xclip", ["-selection", "clipboard"]))
            tools.append(("xsel", ["--clipboard", "--input"]))
        }
        return tools
        #endif
    }

    static func find(_ tool: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Opens a page in this machine's default browser.
enum Browser {
    static func open(_ url: URL) -> Bool {
        #if os(macOS)
        let tool = "open"
        #else
        let tool = "xdg-open"
        #endif
        guard let executable = Clipboard.find(tool) else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// A failure the CLI reports as its own message, without ArgumentParser's help.
struct CLIFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
