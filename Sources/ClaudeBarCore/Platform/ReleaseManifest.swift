import Crypto
import Foundation

/// The Linux build of a release, as `claudebar-linux.json` beside its archives
/// on the GitHub release describes it.
public struct ReleaseManifest: Sendable, Codable {
    public struct Asset: Sendable, Codable {
        public let url: URL
        public let length: Int
        /// Base64 Ed25519 signature over the archive, as Sparkle's sign_update makes it.
        public let signature: String
    }

    public let version: String
    public let build: Int
    /// Keyed by machine architecture as `uname -m` names it: x86_64, aarch64.
    public let assets: [String: Asset]

    /// Always the newest release's manifest.
    public static let latestURL = URL(
        string: "https://github.com/vinnysaj/ClaudeBar/releases/latest/download/claudebar-linux.json")!

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noBuild(architecture: String)
        case lengthMismatch
        case badSignature

        public var description: String {
            switch self {
            case .noBuild(let architecture):
                return "The latest release has no build for \(architecture)."
            case .lengthMismatch, .badSignature:
                return "The download doesn't match what the release signed, so it wasn't installed."
            }
        }
    }

    public func asset(for architecture: String) throws -> Asset {
        guard let asset = self.assets[architecture] else { throw Failure.noBuild(architecture: architecture) }
        return asset
    }

    /// Throws unless `archive` is exactly what the release signed with ClaudeBar's
    /// update key; nothing unverified may be installed.
    public static func verify(_ archive: Data, against asset: Asset, publicKey: String = AppVersion.updatePublicKey) throws {
        guard archive.count == asset.length else { throw Failure.lengthMismatch }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: asset.signature),
              key.isValidSignature(signature, for: archive)
        else { throw Failure.badSignature }
    }
}
