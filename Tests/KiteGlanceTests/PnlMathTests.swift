import XCTest
@testable import KiteGlanceCore

/// Ported from the Windows suite (tests/KiteGlance.Tests/PnlMathTests.cs). The
/// arithmetic must agree across both platforms, so the cases agree too.
final class PnlMathTests: XCTestCase {

    // MARK: - kiteReportedPnl

    func testNilPnlIsNotReported() {
        XCTAssertFalse(PnlMath.kiteReportedPnl(nil))
    }

    /// The MF endpoint returns a literal 0 for holdings it has not computed.
    /// Trusting it zeroes out real money on every fund row.
    func testZeroPnlIsNotReported() {
        XCTAssertFalse(PnlMath.kiteReportedPnl(0))
    }

    func testNonZeroPnlIsReported() {
        XCTAssertTrue(PnlMath.kiteReportedPnl(1))
        XCTAssertTrue(PnlMath.kiteReportedPnl(-1))
    }

    // MARK: - invested

    func testInvestedIsQuantityTimesAveragePrice() {
        XCTAssertEqual(PnlMath.invested(qty: 10, avgPrice: 250), 2500)
    }

    func testInvestedHandlesFractionalMutualFundUnits() {
        XCTAssertEqual(PnlMath.invested(qty: 12.345, avgPrice: 100), 1234.5)
    }

    // MARK: - pnl

    func testPnlComputedFromPricesWhenKiteReportsNothing() {
        let pnl = PnlMath.pnl(qty: 10, avgPrice: 100, lastPrice: 120, apiPnl: nil, awaitingPrice: false)
        XCTAssertEqual(pnl, 200)
    }

    func testPnlPrefersKitesFigureWhenPresent() {
        // Kite's accounting is authoritative when it actually reported one, even
        // where it disagrees with (last - avg) * qty.
        let pnl = PnlMath.pnl(qty: 10, avgPrice: 100, lastPrice: 120, apiPnl: 190, awaitingPrice: false)
        XCTAssertEqual(pnl, 190)
    }

    func testPnlIgnoresKitesZeroAndComputesInstead() {
        let pnl = PnlMath.pnl(qty: 10, avgPrice: 100, lastPrice: 120, apiPnl: 0, awaitingPrice: false)
        XCTAssertEqual(pnl, 200)
    }

    func testUnpricedHoldingHasNoProfitOrLoss() {
        let pnl = PnlMath.pnl(qty: 10, avgPrice: 100, lastPrice: 0, apiPnl: nil, awaitingPrice: true)
        XCTAssertEqual(pnl, 0)
    }

    func testPnlIsNegativeOnALoss() {
        let pnl = PnlMath.pnl(qty: 10, avgPrice: 120, lastPrice: 100, apiPnl: nil, awaitingPrice: false)
        XCTAssertEqual(pnl, -200)
    }

    // MARK: - current

    func testCurrentIsQuantityTimesLastPriceWhenComputed() {
        let current = PnlMath.current(qty: 10, avgPrice: 100, lastPrice: 120, apiPnl: nil, awaitingPrice: false)
        XCTAssertEqual(current, 1200)
    }

    /// Current and P&L must never contradict each other on the same row.
    func testCurrentIsInvestedPlusKitesPnlWhenKiteReported() {
        let current = PnlMath.current(qty: 10, avgPrice: 100, lastPrice: 120, apiPnl: 190, awaitingPrice: false)
        XCTAssertEqual(current, 1190)
    }

    func testUnpricedHoldingIsHeldAtCost() {
        let current = PnlMath.current(qty: 10, avgPrice: 100, lastPrice: 0, apiPnl: nil, awaitingPrice: true)
        XCTAssertEqual(current, 1000)
    }

    func testCurrentAndPnlAgreeWhenKiteReportsAFigure() {
        let invested = PnlMath.invested(qty: 7, avgPrice: 55)
        let pnl = PnlMath.pnl(qty: 7, avgPrice: 55, lastPrice: 61, apiPnl: 33, awaitingPrice: false)
        let current = PnlMath.current(qty: 7, avgPrice: 55, lastPrice: 61, apiPnl: 33, awaitingPrice: false)
        XCTAssertEqual(current, invested + pnl)
    }

    // MARK: - pnlPct

    func testPnlPercentIsRelativeToInvested() {
        XCTAssertEqual(PnlMath.pnlPct(pnl: 200, invested: 1000), 20)
    }

    /// Guards a division by zero on a fully exited or zero-cost position.
    func testPnlPercentIsZeroWhenNothingInvested() {
        XCTAssertEqual(PnlMath.pnlPct(pnl: 200, invested: 0), 0)
    }

    func testPnlPercentIsNegativeOnALoss() {
        XCTAssertEqual(PnlMath.pnlPct(pnl: -250, invested: 1000), -25)
    }

    /// Decimal, not Double: 0.1 + 0.2 must be exactly 0.3 in money math.
    func testDecimalArithmeticDoesNotDrift() {
        let pnl = PnlMath.pnl(qty: 3, avgPrice: 0.1, lastPrice: 0.2, apiPnl: nil, awaitingPrice: false)
        XCTAssertEqual(pnl, Decimal(string: "0.3")!)
    }
}

// MARK: - Rounding

/// Parity check: the Windows `Math.Round(... AwayFromZero)` rounds half values
/// up in absolute magnitude, which is what `MoneyRounding.halfAwayFromZero`
/// here must match. A row showing 0.5 on the rupee total rendering as "₹0"
/// on macOS but "₹1" on Windows would be a real (not cosmetic) divergence.
final class MoneyRoundingTests: XCTestCase {

    func testHalfRoundsAwayFromZeroForPositiveValues() {
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(0.5), 1)
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(1.5), 2)
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(2.5), 3)
    }

    func testHalfRoundsAwayFromZeroForNegativeValues() {
        // AwayFromZero means: take the sign of the input, push the value
        // *away* from zero by the half step. So -0.5 rounds to -1, not 0.
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(-0.5), -1)
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(-1.5), -2)
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(-2.5), -3)
    }

    /// Whole values are unchanged.
    func testIntegersPassThrough() {
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(0), 0)
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(1), 1)
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(-1), -1)
        XCTAssertEqual(MoneyRounding.halfAwayFromZero(1000.5), 1001)
    }

    /// Sanity: the helper is identifying the half boundary correctly so the
    /// tests above exercise what they claim to.
    func testIsExactlyHalfDetectsHalfValues() {
        XCTAssertTrue(MoneyRounding.isExactlyHalf(0.5))
        XCTAssertTrue(MoneyRounding.isExactlyHalf(-0.5))
        XCTAssertTrue(MoneyRounding.isExactlyHalf(1.5))
        XCTAssertFalse(MoneyRounding.isExactlyHalf(0.4))
        XCTAssertFalse(MoneyRounding.isExactlyHalf(0.6))
        XCTAssertFalse(MoneyRounding.isExactlyHalf(0))
    }
}
