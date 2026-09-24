import XCTest
import KiteGlanceCore

/// Settings has a single non-obvious rule: an empty API-secret field on
/// Save means "keep the stored secret" -- the field is deliberately left
/// blank when Settings opens, so writing a non-empty new key without a
/// new secret would silently wipe the stored one. The rule is small but
/// the regression is real, so the rule itself lives in `KiteGlanceCore`
/// (under the name `SecretMerge`) and the test lives here.
///
/// Mirrors the Windows `SettingsWindow.OnSave` parity check, which was
/// the 1.5.0 fix for the same bug.
final class SecretMergeTests: XCTestCase {

    /// A non-empty new secret always wins. The whole point of the
    /// "empty = keep" rule is that an explicitly-typed secret is a
    /// deliberate change, not a no-op.
    func testNonEmptyNewSecretWins() {
        let merged = SecretMerge.resolve(
            newSecret: "newsecret",
            existing: SecretMerge.Existing(apiKey: "k", apiSecret: "old")
        )
        XCTAssertEqual(merged, "newsecret")
    }

    /// The regression the rule was written for. A blank field on Save
    /// with an existing secret must come back as the existing secret,
    /// not an empty string -- which would wipe the stored credential.
    func testEmptyNewSecretKeepsExisting() {
        let merged = SecretMerge.resolve(
            newSecret: "",
            existing: SecretMerge.Existing(apiKey: "k", apiSecret: "old")
        )
        XCTAssertEqual(merged, "old")
    }

    /// Whitespace is treated as empty: typing a single space into the
    /// secret field is not a credential update, and the user is not
    /// trying to set their secret to a space.
    func testWhitespaceOnlyNewSecretIsTreatedAsEmpty() {
        let merged = SecretMerge.resolve(
            newSecret: "   ",
            existing: SecretMerge.Existing(apiKey: "k", apiSecret: "old")
        )
        XCTAssertEqual(merged, "old")
    }

    /// First-time setup: there is no existing secret, and the field is
    /// empty. The result must be `nil` so the Settings UI can show
    /// "The API secret is required" instead of saving an empty string.
    func testEmptyNewSecretWithNoExistingReturnsNil() {
        let merged = SecretMerge.resolve(newSecret: "", existing: nil)
        XCTAssertNil(merged)
    }

    /// First-time setup with a real secret typed in: the result is
    /// the typed value.
    func testNonEmptyNewSecretWithNoExistingReturnsIt() {
        let merged = SecretMerge.resolve(newSecret: "typed", existing: nil)
        XCTAssertEqual(merged, "typed")
    }

    /// Trailing/leading whitespace in a real secret is preserved --
    /// only an entirely-blank value is treated as "keep". A user who
    /// genuinely has a secret with a trailing space (unusual but
    /// legal) would otherwise be unable to save it.
    func testSecretWithInternalPaddingIsPreserved() {
        let merged = SecretMerge.resolve(
            newSecret: "  padded  ",
            existing: nil
        )
        XCTAssertEqual(merged, "  padded  ")
    }
}
