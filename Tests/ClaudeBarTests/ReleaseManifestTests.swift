import Crypto
import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("Release verification")
struct ReleaseManifestTests {
    private static let key = Curve25519.Signing.PrivateKey()
    private static let publicKey = Self.key.publicKey.rawRepresentation.base64EncodedString()
    private static let archive = Data("a release archive".utf8)

    private static func asset(signing data: Data, with key: Curve25519.Signing.PrivateKey = Self.key, length: Int? = nil) throws -> ReleaseManifest.Asset {
        ReleaseManifest.Asset(
            url: URL(string: "https://example.com/claudebar.tar.gz")!,
            length: length ?? data.count,
            signature: try key.signature(for: data).base64EncodedString())
    }

    @Test("The archive the release signed verifies")
    func signedArchiveVerifies() throws {
        try ReleaseManifest.verify(Self.archive, against: Self.asset(signing: Self.archive), publicKey: Self.publicKey)
    }

    enum Tampering: CaseIterable {
        case alteredByte
        case signedByAnotherKey
        case wrongLength
    }

    @Test("Anything else is refused", arguments: Tampering.allCases)
    func tamperedArchiveIsRefused(_ tampering: Tampering) throws {
        var archive = Self.archive
        let asset: ReleaseManifest.Asset
        switch tampering {
        case .alteredByte:
            asset = try Self.asset(signing: archive)
            archive[archive.startIndex] ^= 1
        case .signedByAnotherKey:
            asset = try Self.asset(signing: archive, with: Curve25519.Signing.PrivateKey())
        case .wrongLength:
            asset = try Self.asset(signing: archive, length: archive.count + 1)
        }
        #expect(throws: ReleaseManifest.Failure.self) {
            try ReleaseManifest.verify(archive, against: asset, publicKey: Self.publicKey)
        }
    }
}
