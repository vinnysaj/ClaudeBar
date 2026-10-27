import ClaudeBarCore

/// What ClaudeBar does with the sign-in page when a sign-in starts from the panel.
enum SignInLinkBehavior: String, Codable, CaseIterable, Sendable {
    /// Opens it in the default browser.
    case open
    /// Copies its link, to open in whichever browser profile belongs to the account.
    case copy

    private static let defaultsKey = "signInLinkBehavior"

    static var saved: SignInLinkBehavior {
        get { Preferences.read(SignInLinkBehavior.self, key: Self.defaultsKey) ?? .open }
        set { Preferences.write(newValue, key: Self.defaultsKey) }
    }
}
