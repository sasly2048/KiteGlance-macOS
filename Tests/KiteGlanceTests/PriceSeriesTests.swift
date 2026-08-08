import XCTest
@testable import KiteGlanceCore

final class PriceSeriesTests: XCTestCase {

    /// The reason the skip exists, as a test.
    ///
    /// A 5-minute refresh across a closed weekend appends the same Friday close
    /// hundreds of times. Without the consecutive-identical guard those samples
    /// evict every real point and the sparkline is flat on Monday morning --
    /// exactly when it is looked at. With the guard, a quiet market leaves the
    /// existing shape standing.
    func testWeekendOfIdenticalPricesDoesNotFlushRealPoints() {
        var series = PriceSeries()

        // A real trading session: distinct, moving prices.
        for price in stride(from: 100.0, to: 130.0, by: 1.0) {
            series.append(price)
        }
        let afterTrading = series.points

        // The market closes. 576 refreshes, all quoting the same last price.
        for _ in 0..<576 {
            series.append(129.0)
        }

        XCTAssertEqual(series.points, afterTrading,
                       "identical closing prices must not evict the real session")
        XCTAssertTrue(series.isRenderable)
        XCTAssertNotEqual(series.points.min(), series.points.max(),
                          "series must not have flatlined")
    }

    func testConsecutiveIdenticalPricesAreSkipped() {
        var series = PriceSeries()
        series.append(100)
        series.append(100)
        series.append(100)

        XCTAssertEqual(series.points, [100])
    }

    /// A price that returns to an earlier value is a real move, not a repeat.
    func testNonConsecutiveRepeatIsRecorded() {
        var series = PriceSeries()
        series.append(100)
        series.append(105)
        series.append(100)

        XCTAssertEqual(series.points, [100, 105, 100])
    }

    func testCapacityIsBounded() {
        var series = PriceSeries()
        for i in 0..<200 {
            series.append(Double(i) + 1)
        }

        XCTAssertEqual(series.points.count, PriceSeries.capacity)
        XCTAssertEqual(series.points.last, 200)
    }

    func testNonPositivePricesAreIgnored() {
        var series = PriceSeries()
        series.append(0)
        series.append(-5)

        XCTAssertTrue(series.points.isEmpty)
    }

    func testSinglePointIsNotRenderable() {
        var series = PriceSeries()
        series.append(100)

        XCTAssertFalse(series.isRenderable)
        XCTAssertTrue(series.normalised().isEmpty)
    }

    /// Direction comes from the series' own window, not from total P&L: a
    /// holding down overall but recovering must draw a rising line.
    func testDirectionFollowsTheSeriesNotTotalPnl() {
        var recovering = PriceSeries()
        recovering.append(80)
        recovering.append(90)
        XCTAssertTrue(recovering.isRising)

        var slipping = PriceSeries()
        slipping.append(120)
        slipping.append(110)
        XCTAssertFalse(slipping.isRising)
    }

    /// Each row scales against its own min/max, so a ₹50 stock and a ₹5000 one
    /// both use the full row height.
    func testNormalisationUsesTheSeriesOwnRange() {
        var series = PriceSeries()
        series.append(100)
        series.append(150)
        series.append(200)

        let points = series.normalised()

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(points[2].x, 1, accuracy: 0.0001)
        // y is flipped for view space: the highest price sits at the top (0).
        XCTAssertEqual(points[0].y, 1, accuracy: 0.0001)
        XCTAssertEqual(points[1].y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(points[2].y, 0, accuracy: 0.0001)
    }

    /// Only reachable if two equal points are seeded directly rather than
    /// appended; it must still not divide by a zero range.
    func testFlatSeriesSitsOnTheMidLine() {
        let series = PriceSeries(points: [100, 100])
        let points = series.normalised()

        XCTAssertEqual(points.count, 2)
        for point in points {
            XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
        }
    }

    func testHistoryPrunesSoldSymbols() {
        var history = PriceHistory()
        history.record(symbol: "INFY", price: 100)
        history.record(symbol: "TCS", price: 200)

        history.prune(keeping: ["INFY"])

        XCTAssertEqual(Array(history.series.keys), ["INFY"])
    }

    func testHistoryRoundTripsThroughJSON() throws {
        var history = PriceHistory()
        history.record(symbol: "INFY", price: 100)
        history.record(symbol: "INFY", price: 105)

        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(PriceHistory.self, from: data)

        XCTAssertEqual(decoded, history)
        XCTAssertEqual(decoded["INFY"].points, [100, 105])
    }
}
