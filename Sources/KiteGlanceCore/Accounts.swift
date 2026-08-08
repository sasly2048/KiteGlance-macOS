import Foundation

/// One signed-in Kite account, as remembered between launches.
///
/// The `id` is the Kite user id (`AB1234`), which is also what suffixes this
/// account's Keychain items. `label` is only ever cosmetic -- the menu shows it,
/// nothing resolves against it.
public struct AccountRef: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Which account the app should actually use, given what is remembered and what
/// is genuinely in the vault.
///
/// This exists as a free function, separate from `WidgetState`, for two
/// reasons. It has to take the credential probe as a *parameter*: `WidgetState`
/// is `Codable`, and a stored closure is neither encodable nor `Sendable`, so
/// the probe cannot live on the state. And as a pure function it is unit
/// testable without a Keychain, which is the whole point -- see below.
public enum AccountResolver {
    /// The chosen account, or `nil` when nothing usable is stored.
    ///
    /// The `probe` answers one question: does *this* account id have credentials
    /// in the vault? Every returned id has been probed true.
    ///
    /// The check is the entire point of this function. The Windows build shipped
    /// without it and the bug was this: signing in recorded the Kite user id
    /// purely so the account could be *labelled* in the menu, and a non-empty
    /// account list was then treated as proof that per-account credentials
    /// existed. They did not. The app read an empty vault, built a login URL
    /// with `api_key=` empty, and Kite served an error page -- with the account
    /// still listed in the menu, looking signed in. A labelled account is a
    /// name, not a credential; only the vault can answer that, so only the probe
    /// is trusted here.
    public static func resolvedAccountId(
        accounts: [AccountRef],
        activeAccountId: String?,
        probe: (String) -> Bool
    ) -> String? {
        if let activeAccountId,
           accounts.contains(where: { $0.id == activeAccountId }),
           probe(activeAccountId) {
            return activeAccountId
        }

        // The remembered account is gone or has no credentials. Fall back to the
        // first listed account that actually does -- never merely the first
        // listed one.
        return accounts.first(where: { probe($0.id) })?.id
    }
}
