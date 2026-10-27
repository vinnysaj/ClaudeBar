import Foundation

/// Why a stored login couldn't be read or written.
enum CredentialError: Error, CustomStringConvertible {
    case notFound
    case accessDenied
    case cancelled
    case missingEntitlement
    case unexpected(String)

    var description: String {
        switch self {
        case .notFound: return "Credentials not found"
        case .accessDenied: return "Access to the credentials was denied"
        case .cancelled: return "The keychain prompt was cancelled"
        case .missingEntitlement: return "Keychain entitlement missing"
        case .unexpected(let reason): return "Credential storage failed (\(reason))"
        }
    }
}

// `CredentialStore` reads and writes the two kinds of stored login, with one
// implementation per platform:
//
// - The live login: the credentials Claude Code itself runs on. Switching
//   accounts rewrites them, and the CLI rewrites them when it refreshes.
// - The roster: ClaudeBar's own copy of every account's credentials, one JSON
//   object keyed by account uuid.
//
// Plus the credentials `claude auth login` leaves for a sign-in run in a config
// home of ClaudeBar's own (see `SignInHome`).
extension CredentialStore {
    /// Claude Code's file of credentials, where it keeps them without a keychain.
    static var claudeCredentialsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
    }

    /// Where a sign-in run with `home` as its config home leaves credentials
    /// when there's no keychain.
    static func signInCredentialsFile(home: URL) -> URL {
        home.appendingPathComponent(".credentials.json")
    }
}
