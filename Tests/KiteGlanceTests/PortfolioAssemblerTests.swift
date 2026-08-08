import XCTest
@testable import KiteGlanceCore

/// Exercises the rules that used to be reachable only through a live HTTP call.
/// `KiteService` is an actor that owned both the network and this arithmetic,
/// which is why the day-P&L fix shipped untested.
final class PortfolioAssemblerTests: XCTestCase {

    /// The day-P&L fix, as a test that fails without it.
    ///
    /// T1 stock was bought today and held no position at yesterday's close, so
    /// crediting it a full day's move inflates the day figure and makes the
    /// widget disagree with the Kite app. Only the settled `quantity` counts.
    func testDayPnlExcludesT1Quantity() {
        let holding = EquityHolding(
            tradingsymbol: "INFY",
            quantity: 10,            // settled
            t1_quantity: 90,         // bought today
            average_price: 100,
            last_price: 110,
            close_price: 100
        )

        let portfolio = PortfolioAssembler.assemble(equity: [holding], funds: [])

        // 10 settled shares * ₹10 move. Counting the T1 shares would give ₹1000.
        XCTAssertEqual(portfolio.dayPnl, 100)
    }

    /// The value of the position still counts every share -- you own the T1
    /// stock either way. Only *today's move* excludes it.
    func testHoldingQuantityStillIncludesT1() {
        let holding = EquityHolding(
            tradingsymbol: "INFY",
            quantity: 10,
            t1_quantity: 90,
            average_price: 100,
            last_price: 110,
            close_price: 100
        )

        let portfolio = PortfolioAssembler.assemble(equity: [holding], funds: [])

        XCTAssertEqual(portfolio.holdings.first?.qty, 100)
    }

    /// A newly listed or unpriced holding reports close_price 0. Without the
    /// guard, `last - 0` books the entire position as today's gain.
    func testZeroClosePriceDoesNotBookTheWholePositionAsDayGain() {
        let holding = EquityHolding(
            tradingsymbol: "NEWLISTING",
            quantity: 100,
            average_price: 50,
            last_price: 500,
            close_price: 0
        )

        let portfolio = PortfolioAssembler.assemble(equity: [holding], funds: [])

        XCTAssertEqual(portfolio.dayPnl, 0)
    }

    func testExplicitDayChangeWinsOverClosePrice() {
        let holding = EquityHolding(
            tradingsymbol: "INFY",
            quantity: 10,
            average_price: 100,
            last_price: 110,
            close_price: 100,
            day_change: 5   // Kite's own figure
        )

        let portfolio = PortfolioAssembler.assemble(equity: [holding], funds: [])

        XCTAssertEqual(portfolio.dayPnl, 50)
    }

    func testZeroQuantityHoldingsAreDropped() {
        let sold = EquityHolding(
            tradingsymbol: "SOLD",
            quantity: 0,
            average_price: 100,
            last_price: 110
        )

        let portfolio = PortfolioAssembler.assemble(equity: [sold], funds: [])

        XCTAssertTrue(portfolio.holdings.isEmpty)
    }

    /// An unpriced holding is held at cost rather than marked to a zero Kite
    /// never quoted.
    func testUnpricedHoldingIsHeldAtCost() throws {
        let holding = EquityHolding(
            tradingsymbol: "PENDING",
            quantity: 10,
            average_price: 100,
            last_price: 0
        )

        let portfolio = PortfolioAssembler.assemble(equity: [holding], funds: [])
        let row = try XCTUnwrap(portfolio.holdings.first)

        XCTAssertEqual(row.lastPrice, 100)
        XCTAssertTrue(row.awaitingPrice)
        XCTAssertEqual(row.pnl, 0)
    }

    /// AMFI's live NAV replaces Kite's stale settlement figure, and Kite's P&L
    /// must be dropped with it -- a P&L computed against a stale NAV cannot
    /// annotate a live one.
    func testLiveNavOverridesKiteNavAndDiscardsItsPnl() {
        let fund = MFHolding(
            fundName: "Parag Parikh Flexi Cap",
            tradingsymbol: "INF879O01027",
            quantity: 100,
            average_price: 50,
            last_price: 55,     // Kite's stale settlement NAV
            pnl: 500
        )

        let portfolio = PortfolioAssembler.assemble(
            equity: [],
            funds: [fund],
            liveNavs: ["INF879O01027": 60]
        )
        let row = portfolio.holdings.first

        XCTAssertEqual(row?.lastPrice, 60)
        XCTAssertNil(row?.apiPnl)
        // Recomputed against the live NAV: (60 - 50) * 100.
        XCTAssertEqual(row?.pnl, 1000)
    }

    func testKiteNavIsKeptWhenAmfiLacksTheIsin() {
        let fund = MFHolding(
            fundName: "Some Fund",
            tradingsymbol: "INF000000000",
            quantity: 100,
            average_price: 50,
            last_price: 55,
            pnl: 500
        )

        let portfolio = PortfolioAssembler.assemble(
            equity: [],
            funds: [fund],
            liveNavs: ["INF879O01027": 60]
        )

        XCTAssertEqual(portfolio.holdings.first?.lastPrice, 55)
        XCTAssertEqual(portfolio.holdings.first?.apiPnl, 500)
    }

    /// A blank fund name is Kite saying "not allotted yet", not a fund actually
    /// called nothing.
    func testBlankNamesFallBackToPlaceholders() {
        let portfolio = PortfolioAssembler.assemble(
            equity: [EquityHolding(tradingsymbol: "   ", quantity: 1, average_price: 1, last_price: 1)],
            funds: [MFHolding(fundName: "", quantity: 1, average_price: 1, last_price: 1)]
        )

        XCTAssertEqual(portfolio.holdings.first(where: { !$0.isMutualFund })?.symbol, "Unnamed holding")
        XCTAssertEqual(portfolio.holdings.first(where: { $0.isMutualFund })?.symbol, "Awaiting allotment")
    }

    /// The percentage is taken against yesterday's close, not against today's
    /// value, and must not divide by zero on an empty portfolio.
    func testDayPercentIsAgainstPreviousCloseAndSurvivesAnEmptyPortfolio() {
        let holding = EquityHolding(
            tradingsymbol: "INFY",
            quantity: 10,
            average_price: 100,
            last_price: 110,
            close_price: 100
        )

        let portfolio = PortfolioAssembler.assemble(equity: [holding], funds: [])
        // ₹100 gained on a ₹1000 previous close.
        XCTAssertEqual(portfolio.dayPnlPct, 10)

        let empty = PortfolioAssembler.assemble(equity: [], funds: [])
        XCTAssertEqual(empty.dayPnlPct, 0)
        XCTAssertEqual(empty.dayPnl, 0)
    }
}
