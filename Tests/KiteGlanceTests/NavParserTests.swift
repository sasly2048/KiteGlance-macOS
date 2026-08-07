import XCTest
@testable import KiteGlanceCore

/// Ported from tests/KiteGlance.Tests/AmfiNavServiceTests.cs.
final class NavParserTests: XCTestCase {

    /// A realistic slice of NAVAll.txt: a section header, an AMC name, the
    /// column header, then data rows.
    private let sample = """
        Open Ended Schemes(Equity Scheme - Large Cap Fund)

        Aditya Birla Sun Life Mutual Fund

        Scheme Code;ISIN Div Payout/ISIN Growth;ISIN Div Reinvestment;Scheme Name;Net Asset Value;Date
        119551;INF209K01XX1;INF209K01YY9;Aditya Birla Sun Life Frontline Equity Fund - Growth;432.5678;05-Aug-2026
        119552;INF209K01ZZ7;;Aditya Birla Sun Life Focused Fund - Growth;112.3400;05-Aug-2026
        """

    func testParsesGrowthIsin() {
        let navs = NavParser.parse(sample)
        XCTAssertEqual(navs["INF209K01XX1"], Decimal(string: "432.5678"))
    }

    /// Kite's MF tradingsymbol may be either ISIN column, so both are indexed.
    func testParsesReinvestmentIsin() {
        let navs = NavParser.parse(sample)
        XCTAssertEqual(navs["INF209K01YY9"], Decimal(string: "432.5678"))
    }

    func testParsesRowWithOnlyAGrowthIsin() {
        let navs = NavParser.parse(sample)
        XCTAssertEqual(navs["INF209K01ZZ7"], Decimal(string: "112.34"))
    }

    func testSkipsHeadersSectionTitlesAndAmcNames() {
        let navs = NavParser.parse(sample)
        XCTAssertEqual(navs.count, 3)
    }

    /// Regression: `maxSplits: 4` merged the NAV and date columns into one
    /// field ("432.5678;05-Aug-2026"), so every row failed to parse.
    func testNavIsNotContaminatedByTheTrailingDateColumn() {
        let navs = NavParser.parse(sample)
        XCTAssertEqual(navs["INF209K01XX1"], Decimal(string: "432.5678"))
        XCTAssertFalse(navs.isEmpty, "all rows failed to parse")
    }

    func testSkipsUnpricedSchemes() {
        let text = """
            Scheme Code;ISIN Div Payout/ISIN Growth;ISIN Div Reinvestment;Scheme Name;Net Asset Value;Date
            100000;INF209K01AA1;;Some New Scheme - Growth;N.A.;05-Aug-2026
            """
        XCTAssertTrue(NavParser.parse(text).isEmpty)
    }

    func testSkipsNonPositiveNavs() {
        let text = """
            Scheme Code;ISIN Div Payout/ISIN Growth;ISIN Div Reinvestment;Scheme Name;Net Asset Value;Date
            100000;INF209K01AA1;;Zero Scheme - Growth;0.0000;05-Aug-2026
            """
        XCTAssertTrue(NavParser.parse(text).isEmpty)
    }

    /// An ISIN is always 12 characters; anything else is a malformed row.
    func testSkipsMalformedIsins() {
        let text = """
            Scheme Code;ISIN Div Payout/ISIN Growth;ISIN Div Reinvestment;Scheme Name;Net Asset Value;Date
            100000;SHORT;;Bad Scheme - Growth;100.0000;05-Aug-2026
            """
        XCTAssertTrue(NavParser.parse(text).isEmpty)
    }

    /// Regression: fund names contain semicolons -- "... Fund; Growth Option"
    /// -- and the split was capped at five, so the name's tail stayed glued to
    /// the NAV and the date. Index 4 held " Growth Option" rather than a
    /// number, the Decimal parse failed, and the fund was dropped from the map
    /// entirely, silently falling back to Kite's stale settlement NAV.
    ///
    /// Every sample row above has a clean name, which is exactly why the whole
    /// suite passed while this was broken.
    func testParsesFundsWhoseNameContainsASemicolon() {
        let text = """
            Scheme Code;ISIN Div Payout/ISIN Growth;ISIN Div Reinvestment;Scheme Name;Net Asset Value;Date
            119552;INF209KB1LZ2;INF209KB1MA3;HDFC Gold Fund of Fund; Growth Option;44.0707;07-Aug-2026
            """
        let navs = NavParser.parse(text)

        XCTAssertEqual(navs["INF209KB1LZ2"], Decimal(string: "44.0707"),
                       "a semicolon in the fund name displaced the NAV column")
        XCTAssertEqual(navs["INF209KB1MA3"], Decimal(string: "44.0707"))
    }

    /// A five-field row has no NAV column: index 4 is the date. Admitting it
    /// would parse a date fragment as money.
    func testSkipsRowsWithTooFewFields() {
        let text = """
            Scheme Code;ISIN Div Payout/ISIN Growth;ISIN Div Reinvestment;Scheme Name;Net Asset Value;Date
            100000;INF209K01AA1;;Truncated Scheme;05-Aug-2026
            """
        XCTAssertTrue(NavParser.parse(text).isEmpty)
    }

    func testEmptyInputYieldsNoNavs() {
        XCTAssertTrue(NavParser.parse("").isEmpty)
    }

    /// Regression: `Decimal(string:)` defaults to the current locale, so on a
    /// comma-decimal machine "432.5678" parsed as 4325678.
    func testNavParsingIsLocaleIndependent() {
        let navs = NavParser.parse(sample)
        let nav = try? XCTUnwrap(navs["INF209K01XX1"])
        XCTAssertNotNil(nav)
        XCTAssertLessThan(nav!, 1000, "decimal separator was misread")
    }
}
