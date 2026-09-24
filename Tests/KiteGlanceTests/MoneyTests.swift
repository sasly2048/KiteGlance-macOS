import XCTest
import Foundation
@testable import KiteGlanceCore

/// The Money formatter is pure `Decimal` -> `String` with no AppKit
/// dependencies, so it lives in `KiteGlanceCore` and has full unit
/// coverage here. The cases pin behaviour the executable uses through
/// the view layer; a regression in the formatter would otherwise only
/// show up as a one-character disagreement between the two platforms.
final class MoneyTests: XCTestCase {

    // ---- rupees ----------------------------------------------------------

    /// Below 1,000: show with paise (the only place we keep them).
    func testRupees_underThousandKeepsPaise() {
        XCTAssertEqual(Money.rupees(123.45), "₹123.45")
        XCTAssertEqual(Money.rupees(0.5), "₹0.50")
    }

    /// 1,000 - 99,999: whole rupees, grouped.
    func testRupees_thousandsShowWholeRupeesGrouped() {
        XCTAssertEqual(Money.rupees(1_234), "₹1,234")
        XCTAssertEqual(Money.rupees(99_999), "₹99,999")
    }

    /// 100,000 - 9,999,999: lakh abbreviation.
    func testRupees_lakhsAbbreviate() {
        XCTAssertEqual(Money.rupees(100_000), "₹1.00L")
        XCTAssertEqual(Money.rupees(1_50_000), "₹1.50L")  // 150,000 = 1.50L
        XCTAssertEqual(Money.rupees(99_99_999), "₹100.00L")
    }

    /// >= 10,000,000: crore abbreviation.
    func testRupees_croresAbbreviate() {
        XCTAssertEqual(Money.rupees(10_000_000), "₹1.00Cr")
        XCTAssertEqual(Money.rupees(1_23_45_678), "₹1.23Cr")
    }

    /// Negative amounts are prefixed with the typographic minus sign
    /// (U+2212), not the ASCII hyphen. The two glyphs are visually
    /// identical but a screen reader will say "minus" for the
    /// Unicode one and "hyphen" for the ASCII one -- and the rest of
    /// the widget uses U+2212, so the formatter matches.
    func testRupees_negativeUsesUnicodeMinus() {
        let s = Money.rupees(-1_234)
        XCTAssertTrue(s.hasPrefix("−"), "Expected U+2212, got: \(s)")
    }

    /// Half-away-from-zero: 999.5 rounds to 1000, not 999. This is
    /// the platform-parity rule: Windows uses
    /// `Math.Round(... AwayFromZero)`, and the Mac matches.
    func testRupees_halfAwayFromZeroRoundsUp() {
        // 999.5 is below the 1,000 whole-rupee boundary; rounding
        // half-up gives 1000, which then enters the >= 1,000 branch.
        XCTAssertEqual(Money.rupees(999.5), "₹1,000")
    }

    /// Half-away-from-zero for negative: -999.5 rounds to -1000, not -999.
    /// The previous default was half-to-even, which would have produced
    /// -1000 here too, but only by coincidence -- half-to-even on
    /// -999.5 with the magnitude rounds to -1000 *and* -999 round the
    /// same way, so a regression that flipped back to half-to-even
    /// would not always show. The 9994.5 case is the unambiguous
    /// "half-up" check.
    func testRupees_halfAwayFromZeroOnNegativeMagnitude() {
        // |x| = 9994.5 -- the half is in the units digit of the
        // 4-digit number, well past the .5 noise floor. Half-up
        // gives 9995.
        XCTAssertEqual(Money.rupees(-9994.5), "−₹9,995")
    }

    // ---- signed ----------------------------------------------------------

    /// Positive amounts are prefixed with `+`; negative with the
    /// Unicode minus. The double-sign case (-₹-1,234) is not
    /// possible because `signed` only sees the *magnitude* when
    /// delegating to `rupees`.
    func testSigned_alwaysHasExplicitSign() {
        XCTAssertEqual(Money.signed(1_234), "+₹1,234")
        XCTAssertEqual(Money.signed(-1_234), "−₹1,234")
        XCTAssertEqual(Money.signed(0), "+₹0.00")
    }

    // ---- percent ---------------------------------------------------------

    /// Percent uses the same half-away-from-zero rule.
    func testPercent_halfAwayFromZeroRoundsUp() {
        XCTAssertEqual(Money.percent(0.5), "+0.50%")
        XCTAssertEqual(Money.percent(-0.5), "−0.50%")
        XCTAssertEqual(Money.percent(12.345), "+12.35%")
    }

    /// Zero percent is rendered with a sign. A no-sign zero is also
    /// plausible, but the rest of the UI uses the same prefix rule
    /// so the consistency wins.
    func testPercent_zeroHasPositiveSign() {
        XCTAssertEqual(Money.percent(0), "+0.00%")
    }

    // ---- exact -----------------------------------------------------------

    /// The un-abbreviated, un-rounded formatter used in tooltips.
    func testExact_keepsPaise() {
        XCTAssertEqual(Money.exact(1_234.56), "₹1,234.56")
        XCTAssertEqual(Money.exact(0.5), "₹0.50")
    }
}
