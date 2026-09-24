import Foundation

/// The Settings save rule, extracted so it can be unit-tested without
/// pulling in the Keychain.
///
/// A blank API-secret field on Save means "keep the stored secret". The
/// Settings window deliberately does not echo the secret back when it
/// opens, so without this rule the first Save after a successful setup
/// would silently wipe the stored secret. Mirrors the Windows
/// `SettingsWindow.OnSave` rule introduced for the same reason in 1.5.0.
public enum SecretMerge {
    /// The values a successful load returns, sufficient to decide whether
    /// the user has anything already stored.
    public struct Existing: Equatable {
        public let apiKey: String
        public let apiSecret: String

        public init(apiKey: String, apiSecret: String) {
            self.apiKey = apiKey
            self.apiSecret = apiSecret
        }
    }

    /// The resolved secret to write. `nil` means "do not save -- the
    /// user has not entered a secret and there is nothing to keep",
    /// which the UI surfaces as "The API secret is required".
    public static func resolve(newSecret: String, existing: Existing?) -> String? {
        let trimmed = newSecret.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return newSecret
        }
        return existing?.apiSecret
    }
}
