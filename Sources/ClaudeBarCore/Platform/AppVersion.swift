/// The release this build belongs to. `release/release.sh prepare` keeps it in
/// step with MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project.
public enum AppVersion {
    public static let marketing = "4.0.1"
    /// Compared to decide whether a release is newer.
    public static let build = 18
    /// The Ed25519 key Linux updates are signed with: the same one Sparkle checks
    /// Mac updates against (SUPublicEDKey in the app's Info.plist).
    public static let updatePublicKey = "KGfoufNhtgpfWr15LboH5pbfO4y8WV6F5d1sask/iHA="
}
