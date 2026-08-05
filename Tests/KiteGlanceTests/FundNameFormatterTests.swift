import XCTest
@testable import KiteGlanceCore

final class FundNameFormatterTests: XCTestCase {

    func testStripsPlanAndOptionSuffixes() {
        let pretty = FundNameFormatter.prettyName("HDFC MID-CAP OPPORTUNITIES FUND - DIRECT PLAN - GROWTH")
        XCTAssertFalse(pretty.uppercased().contains("DIRECT PLAN"))
        XCTAssertFalse(pretty.uppercased().contains("GROWTH"))
    }

    func testKeepsBrandAcronymsUppercase() {
        XCTAssertTrue(FundNameFormatter.prettyName("HDFC TOP 100 FUND").hasPrefix("HDFC"))
        XCTAssertTrue(FundNameFormatter.prettyName("ICICI PRUDENTIAL BLUECHIP").hasPrefix("ICICI"))
    }

    func testTitleCasesOrdinaryWords() {
        XCTAssertEqual(FundNameFormatter.prettyName("PARAG PARIKH FLEXI CAP"), "Parag Parikh Flexi Cap")
    }

    func testAbbreviatesFundOfFund() {
        XCTAssertTrue(FundNameFormatter.prettyName("MOTILAL OSWAL NASDAQ 100 FUND OF FUND").contains("FoF"))
    }

    /// Regression: collapsing `\s{2,}` to "" instead of " " welded words
    /// together, turning "HDFC  Top 100" into "HDFCTop 100".
    func testCollapsesRunsOfWhitespaceWithoutWeldingWords() {
        XCTAssertEqual(FundNameFormatter.prettyName("HDFC  TOP  100"), "HDFC Top 100")
    }

    /// Regression: the replacement used to be chosen by testing the *pattern*
    /// for "FUND OF FUND", so unrelated patterns could substitute the wrong text.
    func testPlanStrippingDoesNotInjectFoF() {
        XCTAssertFalse(FundNameFormatter.prettyName("SBI BLUECHIP FUND - REGULAR PLAN").contains("FoF"))
    }

    func testEmptyAndBlankNamesGetAPlaceholder() {
        XCTAssertEqual(FundNameFormatter.prettyName(""), "Unnamed")
        XCTAssertEqual(FundNameFormatter.prettyName("   "), "Unnamed")
    }

    func testTrailingSeparatorIsRemoved() {
        XCTAssertFalse(FundNameFormatter.prettyName("AXIS SMALL CAP FUND -").hasSuffix("-"))
    }

    func testNeverReturnsLeadingOrTrailingWhitespace() {
        let pretty = FundNameFormatter.prettyName("  UTI NIFTY INDEX FUND - DIRECT PLAN - GROWTH  ")
        XCTAssertEqual(pretty, pretty.trimmingCharacters(in: .whitespaces))
    }
}
