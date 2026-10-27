import Foundation

/// How the CLI names an account: by its number in `claudebar status`, its email,
/// its id, or as much of its email as tells it apart from the others.
public enum AccountSelector {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noMatch(String)
        case ambiguous(String, matches: [String])

        public var description: String {
            switch self {
            case .noMatch(let selector):
                return "No account matches \"\(selector)\". `claudebar status` lists them."
            case .ambiguous(let selector, let matches):
                return "\"\(selector)\" matches \(matches.joined(separator: ", ")). Give more of the email, or the account's number."
            }
        }
    }

    /// The account `selector` picks out of `displays`, which are in status order.
    /// A number only ever means a position, and an exact email or id wins over
    /// a partial match, so no selector picks a different account than it names.
    public static func resolve(_ selector: String, in displays: [AccountDisplay]) throws -> AccountDisplay {
        let selector = selector.trimmingCharacters(in: .whitespaces)
        if let number = Int(selector) {
            guard displays.indices.contains(number - 1) else { throw Failure.noMatch(selector) }
            return displays[number - 1]
        }
        if let exact = displays.first(where: {
            $0.id == selector || $0.account.email.caseInsensitiveCompare(selector) == .orderedSame
        }) {
            return exact
        }
        let matches = displays.filter { $0.account.email.range(of: selector, options: .caseInsensitive) != nil }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw Failure.noMatch(selector)
        default: throw Failure.ambiguous(selector, matches: matches.map(\.account.email))
        }
    }
}
