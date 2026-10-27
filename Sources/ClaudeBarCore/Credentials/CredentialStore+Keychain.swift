#if os(macOS)
import Crypto
import Foundation
import Security

extension CredentialError {
    static func from(_ status: OSStatus) -> CredentialError {
        switch status {
        case errSecItemNotFound: return .notFound
        case errSecAuthFailed, errSecInteractionNotAllowed: return .accessDenied
        case errSecUserCanceled: return .cancelled
        case errSecMissingEntitlement: return .missingEntitlement
        default: return .unexpected("keychain error \(status)")
        }
    }
}

enum CredentialStore {
    /// How messages name the place logins are kept.
    static let storeName = "the keychain"

    /// The item Claude Code reads its OAuth credentials from.
    static let liveService = "Claude Code-credentials"
    static var liveAccount: String { NSUserName() }
    /// ClaudeBar's roster: a single item holding every managed account's
    /// credential blob (JSON, keyed by accountUuid). It lives in the Data
    /// Protection keychain, where access is granted by code-signing
    /// entitlements (team + access group) instead of per-binary ACLs and
    /// partition lists — no permission dialogs, ever, and access survives app
    /// updates. It stays writable while the Mac is locked: ClaudeBar refreshes
    /// tokens in the background, each refresh retires the previous refresh
    /// token, and one that can't be saved is gone at the next launch, signing
    /// the account out. Bare `swift build` binaries cannot carry the required
    /// entitlement (that needs a provisioning profile), so they transparently
    /// fall back to a file-based login keychain item.
    static let rosterService = "ClaudeBar-accounts"
    static let rosterAccount = "roster"
    /// First keychain access group from this binary's code-signing
    /// entitlements ($(AppIdentifierPrefix) + bundle identifier); nil for
    /// unprovisioned dev builds, which use the file-based fallback.
    private static let rosterAccessGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String]
        else { return nil }
        return groups.first
    }()

    // MARK: - Roster item (Data Protection keychain, file-based fallback)

    static func readRoster() throws -> Data {
        do {
            return try self.read(service: self.rosterService, account: self.rosterAccount, dataProtection: true)
        } catch CredentialError.missingEntitlement {
            // Unprovisioned dev binary: the file-based item is the store.
            return try self.read(service: self.rosterService, account: self.rosterAccount, dataProtection: false)
        }
    }

    static func writeRoster(_ data: Data) throws {
        do {
            try self.write(service: self.rosterService, account: self.rosterAccount, data: data, dataProtection: true)
        } catch CredentialError.missingEntitlement {
            try self.write(service: self.rosterService, account: self.rosterAccount, data: data, dataProtection: false)
        }
    }

    private static func query(service: String, account: String, dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
            if let group = self.rosterAccessGroup {
                query[kSecAttrAccessGroup] = group
            }
        }
        return query
    }

    private static func read(service: String, account: String, dataProtection: Bool) throws -> Data {
        var query = self.query(service: service, account: account, dataProtection: dataProtection)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialError.from(status)
        }
        return data
    }

    /// Update-if-exists, add otherwise. Only for ClaudeBar's own items — the
    /// live Claude Code item must go through `writeLiveBlob` instead.
    private static func write(service: String, account: String, data: Data, dataProtection: Bool) throws {
        let query = self.query(service: service, account: account, dataProtection: dataProtection)
        var attributes: [CFString: Any] = [kSecValueData: data]
        if dataProtection {
            // On update as well as add: an existing item keeps whatever
            // accessibility it was stored with until a write changes it.
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        }
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialError.from(status) }

        let add = query.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialError.from(addStatus) }
    }

    // MARK: - Live credential blob (keychain, with file fallback)
    //
    // The claude CLI reads and writes this item by shelling out to
    // /usr/bin/security, which keeps it in the "apple-tool:" keychain
    // partition. Any write from a different signing identity — including a
    // native SecItemUpdate from ClaudeBar — rewrites the partition list to
    // the writer's team, after which the CLI's own reads fail the partition
    // check and macOS demands the login keychain password on every `claude`
    // launch. So ClaudeBar goes through /usr/bin/security for both reads and
    // writes, exactly like the CLI: the item stays in the apple-tool:
    // partition and neither side prompts.

    static func readLiveBlob() throws -> Data {
        do {
            return try self.readCLIItem(service: self.liveService)
        } catch CredentialError.notFound {
            // Some installs keep credentials in a plain file instead of the keychain.
            let fileURL = self.claudeCredentialsFile
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw CredentialError.notFound
            }
            return try Data(contentsOf: fileURL)
        }
    }

    static func writeLiveBlob(_ data: Data) throws {
        // Attribute-only probe (no decryption, never prompts) to detect
        // file-based installs, which have no keychain item to update.
        let probe = try Self.runSecurityTool(arguments: [
            "find-generic-password", "-s", self.liveService, "-a", self.liveAccount,
        ])
        if probe.status == 44 { // security(1) exit code for "item not found"
            let fileURL = self.claudeCredentialsFile
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try AppPaths.writePrivateFile(data, to: fileURL)
                return
            }
            // No item and no file: fall through and create the item, exactly
            // as a CLI /login would.
        }

        // The hex payload rides on argv, matching what the claude CLI itself
        // does for blobs this size (`security -i` caps stdin lines at ~4KB).
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let result = try Self.runSecurityTool(arguments: [
            "add-generic-password", "-U",
            "-s", self.liveService, "-a", self.liveAccount, "-X", hex,
        ])
        guard result.status == 0 else {
            throw CredentialError.unexpected("security exited with status \(result.status)")
        }
    }

    // MARK: - Sign-in credentials

    /// What `claude auth login` stored for a sign-in run in `home`: a keychain
    /// item named after the home, or a file in it where there's no keychain.
    static func readSignInCredentials(home: URL) throws -> Data {
        do {
            return try self.readCLIItem(service: self.signInService(home: home))
        } catch CredentialError.notFound {
            let fileURL = self.signInCredentialsFile(home: home)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw CredentialError.notFound }
            return try Data(contentsOf: fileURL)
        }
    }

    /// Deletes the keychain item a sign-in run in `home` left; one that doesn't
    /// exist is already gone. The file, if any, goes with the home.
    static func deleteSignInCredentials(home: URL) throws {
        let result = try Self.runSecurityTool(arguments: [
            "delete-generic-password", "-s", self.signInService(home: home), "-a", self.liveAccount,
        ])
        guard result.status == 0 || result.status == 44 else {
            throw CredentialError.unexpected("security exited with status \(result.status)")
        }
    }

    /// Where the CLI keeps a config home's credentials: the name of Claude Code's
    /// own item, then the first 8 hex digits of the SHA-256 of the home's path in NFC.
    private static func signInService(home: URL) -> String {
        let digest = SHA256.hash(data: Data(home.path.precomposedStringWithCanonicalMapping.utf8))
        let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(self.liveService)-\(prefix)"
    }

    // MARK: - security(1)

    /// A credential item the claude CLI keeps under `service`, read through
    /// /usr/bin/security the way the CLI reads it.
    private static func readCLIItem(service: String) throws -> Data {
        let result = try Self.runSecurityTool(arguments: [
            "find-generic-password", "-s", service, "-a", self.liveAccount, "-w",
        ])
        switch result.status {
        case 0:
            var text = result.stdout
            while text.hasSuffix("\n") { text = String(text.dropLast()) }
            guard let data = text.data(using: .utf8), !data.isEmpty else {
                throw CredentialError.unexpected("the keychain item is empty")
            }
            return data
        case 44: // security(1) exit code for "item not found"
            throw CredentialError.notFound
        default:
            throw CredentialError.accessDenied
        }
    }

    private static func runSecurityTool(arguments: [String]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CredentialError.unexpected("couldn't run security: \(error.localizedDescription)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
#endif
