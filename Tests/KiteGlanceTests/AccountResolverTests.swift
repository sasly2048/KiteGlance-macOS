import XCTest
@testable import KiteGlanceCore

/// The regression suite for the bug the Windows build shipped: a labelled
/// account was treated as proof that credentials existed.
final class AccountResolverTests: XCTestCase {

    /// The case that matters. Signing in records the Kite user id so the menu
    /// has something to show; that alone must never make the account usable.
    ///
    /// Without the probe check this returns "AB1234", the app builds a login URL
    /// with an empty api_key, and Kite serves an error page while the menu still
    /// shows the account as present.
    func testLabelledAccountWithNoCredentialsResolvesToNil() {
        let accounts = [AccountRef(id: "AB1234", label: "Personal")]

        let resolved = AccountResolver.resolvedAccountId(
            accounts: accounts,
            activeAccountId: "AB1234",
            probe: { _ in false }   // labelled, but the vault is empty
        )

        XCTAssertNil(resolved)
    }

    /// The same failure without an explicitly active account: falling back to
    /// "the first one listed" is precisely the wrong fallback.
    func testFallbackSkipsLabelledAccountsWithoutCredentials() {
        let accounts = [
            AccountRef(id: "AB1234", label: "Labelled only"),
            AccountRef(id: "CD5678", label: "Actually signed in")
        ]

        let resolved = AccountResolver.resolvedAccountId(
            accounts: accounts,
            activeAccountId: nil,
            probe: { $0 == "CD5678" }
        )

        XCTAssertEqual(resolved, "CD5678")
    }

    func testActiveAccountWithCredentialsIsUsed() {
        let accounts = [
            AccountRef(id: "AB1234", label: "One"),
            AccountRef(id: "CD5678", label: "Two")
        ]

        let resolved = AccountResolver.resolvedAccountId(
            accounts: accounts,
            activeAccountId: "CD5678",
            probe: { _ in true }
        )

        XCTAssertEqual(resolved, "CD5678")
    }

    /// A remembered id that is no longer in the list must not be returned even
    /// if some *other* account would probe true.
    func testActiveAccountNoLongerListedFallsBackToACredentialledOne() {
        let accounts = [AccountRef(id: "CD5678", label: "Two")]

        let resolved = AccountResolver.resolvedAccountId(
            accounts: accounts,
            activeAccountId: "GONE99",
            probe: { _ in true }
        )

        XCTAssertEqual(resolved, "CD5678")
    }

    func testNoAccountsResolvesToNil() {
        XCTAssertNil(
            AccountResolver.resolvedAccountId(
                accounts: [],
                activeAccountId: nil,
                probe: { _ in true }
            )
        )
    }

    /// Every returned id must have been probed true -- not merely present.
    func testEveryResolvedIdWasProbed() {
        var probed: [String] = []
        let accounts = [AccountRef(id: "AB1234", label: "One")]

        let resolved = AccountResolver.resolvedAccountId(
            accounts: accounts,
            activeAccountId: "AB1234",
            probe: { id in probed.append(id); return true }
        )

        XCTAssertEqual(resolved, "AB1234")
        XCTAssertTrue(probed.contains("AB1234"))
    }
}
