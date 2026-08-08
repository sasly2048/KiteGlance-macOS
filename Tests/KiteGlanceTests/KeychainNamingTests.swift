import XCTest
@testable import KiteGlanceCore

final class KeychainNamingTests: XCTestCase {

    /// The upgrade path. Credentials written before multi-account existed live
    /// under the bare name; if `nil` suffixed to "credentials@" they would be
    /// orphaned, and an existing user would be shown the connect screen while
    /// their key sat in the Keychain under a name nothing reads.
    func testNoAccountKeepsTheUnsuffixedName() {
        XCTAssertEqual(KeychainNaming.itemName(base: "credentials", accountId: nil), "credentials")
        XCTAssertEqual(KeychainNaming.itemName(base: "credentials", accountId: ""), "credentials")
    }

    func testEachAccountGetsItsOwnItem() {
        let first = KeychainNaming.itemName(base: "credentials", accountId: "AB1234")
        let second = KeychainNaming.itemName(base: "credentials", accountId: "CD5678")

        XCTAssertEqual(first, "credentials@AB1234")
        XCTAssertNotEqual(first, second)
    }

    /// The key/secret blob and the daily token are separate items, per account,
    /// so refreshing a token never rewrites the long-lived credentials.
    func testTokenAndCredentialsDoNotCollide() {
        XCTAssertNotEqual(
            KeychainNaming.itemName(base: "credentials", accountId: "AB1234"),
            KeychainNaming.itemName(base: "access-token", accountId: "AB1234")
        )
    }
}
