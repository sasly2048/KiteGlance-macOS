import Foundation
import Security

/// Credentials at rest, in the macOS Keychain.
///
/// The Windows original uses DPAPI (per-user, OS-scoped). The macOS equivalent
/// of that guarantee is a Keychain generic-password item with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: scoped to this user's
/// unlocked login keychain, never synced to iCloud, never restorable onto
/// another machine from a backup.
///
/// Parity note: like the Windows vault, `KITE_API_KEY` / `KITE_API_SECRET`
/// environment variables take priority over stored values, so a developer
/// running from source can keep credentials in the environment instead of
/// retyping them into Settings each launch. Nothing is ever hardcoded.
struct Credentials: Codable, Sendable {
    var apiKey: String
    var apiSecret: String
    var accessToken: String?
    var savedAt: Date
}

actor CredentialVault {
    private let service: String
    private let credentialsAccount = "credentials"
    private let accessTokenAccount = "access-token"

    init(service: String = "com.kiteglance.vault") {
        self.service = service
    }

    // MARK: - Credentials

    /// Stored credentials with the access token folded in. Environment
    /// variables win over the Keychain, matching the Windows vault.
    func load() -> Credentials? {
        let env = ProcessInfo.processInfo.environment
        let envKey = env["KITE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let envSecret = env["KITE_API_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let envKey, let envSecret, !envKey.isEmpty, !envSecret.isEmpty {
            return Credentials(
                apiKey: envKey,
                apiSecret: envSecret,
                accessToken: readString(account: accessTokenAccount),
                savedAt: Date()
            )
        }

        guard let data = readData(account: credentialsAccount),
              var creds = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return nil
        }

        // The token rotates daily and lives in its own item, so refreshing it
        // never rewrites the long-lived key/secret blob.
        creds.accessToken = readString(account: accessTokenAccount)
        return creds
    }

    func save(_ credentials: Credentials) throws {
        var toStore = credentials
        let token = toStore.accessToken
        toStore.accessToken = nil

        try write(try JSONEncoder().encode(toStore), account: credentialsAccount)

        if let token, !token.isEmpty {
            try write(Data(token.utf8), account: accessTokenAccount)
        }
    }

    // MARK: - Access token (rotates daily)

    func updateAccessToken(_ token: String) throws {
        try write(Data(token.utf8), account: accessTokenAccount)
    }

    func clearAccessToken() throws {
        try delete(account: accessTokenAccount)
    }

    func clearAll() throws {
        try delete(account: accessTokenAccount)
        try delete(account: credentialsAccount)
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Upsert. The Keychain has no atomic "set": `SecItemAdd` on an existing
    /// item returns `errSecDuplicateItem` rather than replacing it, so the
    /// update-then-add order is required.
    private func write(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw VaultError(status: addStatus) }
        default:
            throw VaultError(status: status)
        }
    }

    private func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func readString(account: String) -> String? {
        guard let data = readData(account: account),
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else {
            return nil
        }
        return string
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        // Deleting something never stored is a no-op, not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError(status: status)
        }
    }
}

struct VaultError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String?
        return "Keychain error \(status)\(detail.map { ": \($0)" } ?? "")"
    }
}
