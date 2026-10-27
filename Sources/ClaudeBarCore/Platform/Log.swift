#if !canImport(os)
import Foundation

/// Linux stand-in for `os.Logger`, with the same call shape so logging code is
/// shared. Writes to stderr, which journald collects from the daemon. Values
/// logged `.private` are redacted, as unified logging does on the Mac.
struct Logger: Sendable {
    private let label: String

    init(subsystem: String, category: String) {
        self.label = category
    }

    func debug(_ message: LogMessage) {
        self.write("debug", message)
    }

    func info(_ message: LogMessage) {
        self.write("info", message)
    }

    func notice(_ message: LogMessage) {
        self.write("notice", message)
    }

    func error(_ message: LogMessage) {
        self.write("error", message)
    }

    private func write(_ level: String, _ message: LogMessage) {
        FileHandle.standardError.write(Data("[\(self.label)] \(level): \(message.text)\n".utf8))
    }
}

enum LogPrivacy: Sendable {
    case `public`
    case `private`
    case auto
}

struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            self.text.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            self.text += literal
        }

        /// Like unified logging, anything not marked public is redacted unless
        /// it's a number.
        mutating func appendInterpolation<Value>(_ value: Value, privacy: LogPrivacy = .auto) {
            switch privacy {
            case .public:
                self.text += String(describing: value)
            case .private:
                self.text += "<private>"
            case .auto:
                self.text += value is any Numeric ? String(describing: value) : "<private>"
            }
        }
    }

    fileprivate let text: String

    init(stringLiteral value: String) {
        self.text = value
    }

    init(stringInterpolation: StringInterpolation) {
        self.text = stringInterpolation.text
    }
}
#endif
