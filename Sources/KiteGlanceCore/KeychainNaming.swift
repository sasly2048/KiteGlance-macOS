import Foundation

/// How a Keychain item is named for a given account.
///
/// Split out of `CredentialVault` so the upgrade path can be tested: the vault
/// itself touches the real Keychain, which a unit test cannot.
public enum KeychainNaming {
    /// `nil` or an empty account id keeps the unsuffixed name.
    ///
    /// That is not a tidiness choice. Every credential written before
    /// multi-account existed is stored under the bare name, so mapping `nil` to
    /// `credentials@` would orphan them: an existing user would be shown the
    /// "connect" screen on upgrade while their key sat in the Keychain under a
    /// name nothing looks for any more.
    public static func itemName(base: String, accountId: String?) -> String {
        guard let accountId, !accountId.isEmpty else { return base }
        return "\(base)@\(accountId)"
    }
}
