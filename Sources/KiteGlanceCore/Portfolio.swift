import Foundation

/// The portfolio models and the pure assembly that turns Kite's two payloads
/// into rows.
///
/// These lived in `KiteService` -- an actor that also owns the network -- which
/// left the arithmetic reachable only by making real HTTP calls. That is why
/// the day-P&L fix shipped untested. Here the decoding types and the assembly
/// are ordinary values in a library target, so the rules below can be exercised
/// against a literal array of holdings, and `KiteService` keeps only the I/O.

public struct EquityHolding: Decodable, Sendable {
    public let tradingsymbol: String
    /// Needed to ask `/instruments/historical` for this instrument. Optional
    /// because it is absent from older recorded payloads and from mutual funds.
    public let instrument_token: Int?
    public let quantity: Decimal
    public let t1_quantity: Decimal?
    public let average_price: Decimal
    public let last_price: Decimal
    public let close_price: Decimal?
    public let day_change: Decimal?
    public let pnl: Decimal?

    public init(
        tradingsymbol: String,
        instrument_token: Int? = nil,
        quantity: Decimal,
        t1_quantity: Decimal? = nil,
        average_price: Decimal,
        last_price: Decimal,
        close_price: Decimal? = nil,
        day_change: Decimal? = nil,
        pnl: Decimal? = nil
    ) {
        self.tradingsymbol = tradingsymbol
        self.instrument_token = instrument_token
        self.quantity = quantity
        self.t1_quantity = t1_quantity
        self.average_price = average_price
        self.last_price = last_price
        self.close_price = close_price
        self.day_change = day_change
        self.pnl = pnl
    }
}

public struct MFHolding: Decodable, Sendable {
    /// Kite sends this as `fund`, not `fund_name`. Decoding the wrong key made
    /// every fund fall through to the "Awaiting allotment" placeholder.
    public let fundName: String
    public let tradingsymbol: String?
    public let quantity: Decimal
    public let average_price: Decimal
    public let last_price: Decimal
    /// Kite's own P&L. The MF endpoint returns a literal 0 for holdings it has
    /// not computed, so a zero here is an absence, not a fact -- see PnlMath.
    public let pnl: Decimal?

    enum CodingKeys: String, CodingKey {
        case fundName = "fund"
        case tradingsymbol, quantity, average_price, last_price, pnl
    }

    public init(
        fundName: String,
        tradingsymbol: String? = nil,
        quantity: Decimal,
        average_price: Decimal,
        last_price: Decimal,
        pnl: Decimal? = nil
    ) {
        self.fundName = fundName
        self.tradingsymbol = tradingsymbol
        self.quantity = quantity
        self.average_price = average_price
        self.last_price = last_price
        self.pnl = pnl
    }
}

public struct Holding: Identifiable, Hashable, Sendable {
    /// Stable across refreshes: a symbol identifies the same row from one fetch
    /// to the next. A fresh UUID per rebuild would make SwiftUI treat every
    /// refresh as a wholly new list, dropping row animation and hover state.
    public var id: String { "\(isMutualFund ? "mf" : "eq"):\(symbol)" }

    public let symbol: String
    public let qty: Decimal
    public let avgPrice: Decimal
    public let lastPrice: Decimal
    public let isMutualFund: Bool
    public let awaitingPrice: Bool
    public let apiPnl: Decimal?
    /// Equity only. Mutual funds have no historical instrument, which is why
    /// they use the locally accumulated series.
    public let instrumentToken: Int?

    public init(
        symbol: String,
        qty: Decimal,
        avgPrice: Decimal,
        lastPrice: Decimal,
        isMutualFund: Bool,
        awaitingPrice: Bool,
        apiPnl: Decimal?,
        instrumentToken: Int? = nil
    ) {
        self.symbol = symbol
        self.qty = qty
        self.avgPrice = avgPrice
        self.lastPrice = lastPrice
        self.isMutualFund = isMutualFund
        self.awaitingPrice = awaitingPrice
        self.apiPnl = apiPnl
        self.instrumentToken = instrumentToken
    }

    public var invested: Decimal { PnlMath.invested(qty: qty, avgPrice: avgPrice) }

    public var pnl: Decimal {
        PnlMath.pnl(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice,
                    apiPnl: apiPnl, awaitingPrice: awaitingPrice)
    }

    public var current: Decimal {
        PnlMath.current(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice,
                        apiPnl: apiPnl, awaitingPrice: awaitingPrice)
    }

    public var pnlPct: Decimal { PnlMath.pnlPct(pnl: pnl, invested: invested) }
}

public struct PortfolioData: Sendable {
    public let dayPnl: Decimal
    public let dayPnlPct: Decimal
    public let holdings: [Holding]

    public init(dayPnl: Decimal, dayPnlPct: Decimal, holdings: [Holding]) {
        self.dayPnl = dayPnl
        self.dayPnlPct = dayPnlPct
        self.holdings = holdings
    }
}

/// Turns Kite's decoded payloads into the rows the widget shows.
///
/// Pure: no network, no actor, no clock. This is the seam that was missing --
/// every rule below used to be reachable only through a live HTTP call.
public enum PortfolioAssembler {

    /// A holding Kite has not priced yet is held at cost rather than marked to
    /// a zero it never quoted. Returns the price to use and whether it is a
    /// stand-in.
    public static func priced(_ last: Decimal, _ avg: Decimal) -> (price: Decimal, awaiting: Bool) {
        let awaiting = last <= 0 && avg > 0
        return (awaiting ? avg : last, awaiting)
    }

    /// Today's move for one equity holding.
    ///
    /// The `close > 0` guard matters: an unpriced or newly listed holding
    /// reports close_price 0, and `last - 0` would book the entire position as
    /// today's gain, poisoning the portfolio day total.
    public static func dayChange(_ h: EquityHolding) -> Decimal {
        if let dayChange = h.day_change { return dayChange }
        if let close = h.close_price, close > 0 { return h.last_price - close }
        return 0
    }

    /// Assembles the portfolio.
    ///
    /// `liveNavs` overrides Kite's stale settlement NAVs where AMFI has the
    /// ISIN; pass `nil` when AMFI was unreachable.
    public static func assemble(
        equity: [EquityHolding],
        funds: [MFHolding],
        liveNavs: [String: Decimal]? = nil
    ) -> PortfolioData {
        var allHoldings: [Holding] = []
        var dayPnl: Decimal = 0
        var equityCurrent: Decimal = 0

        for h in equity {
            let qty = h.quantity + (h.t1_quantity ?? 0)
            guard qty > 0 else { continue }

            let (lastPrice, awaiting) = priced(h.last_price, h.average_price)
            let change = dayChange(h)

            // Day change applies to settled shares only. T1 stock was bought
            // today and held no position at yesterday's close, so attributing a
            // full day's move to it inflates the day figure and makes it
            // disagree with the Kite app. Holdings *value* below still counts
            // every share -- you own them either way.
            dayPnl += h.quantity * change
            equityCurrent += qty * lastPrice

            allHoldings.append(Holding(
                symbol: h.tradingsymbol.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Unnamed holding"
                    : h.tradingsymbol,
                qty: qty,
                avgPrice: h.average_price,
                lastPrice: lastPrice,
                isMutualFund: false,
                awaitingPrice: awaiting,
                apiPnl: h.pnl,
                instrumentToken: h.instrument_token
            ))
        }

        for f in funds {
            guard f.quantity > 0 else { continue }

            var nav = f.last_price
            var apiPnl: Decimal? = f.pnl

            if let liveNavs,
               let symbol = f.tradingsymbol?.trimmingCharacters(in: .whitespaces),
               !symbol.isEmpty,
               let amfi = liveNavs[symbol],
               amfi > 0 {
                nav = amfi
                apiPnl = nil   // stale-NAV pnl cannot annotate a live NAV
            }

            let (lastPrice, awaiting) = priced(nav, f.average_price)

            allHoldings.append(Holding(
                symbol: f.fundName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Awaiting allotment"
                    : f.fundName,
                qty: f.quantity,
                avgPrice: f.average_price,
                lastPrice: lastPrice,
                isMutualFund: true,
                awaitingPrice: awaiting,
                apiPnl: apiPnl
            ))
        }

        let prevClose = equityCurrent - dayPnl

        return PortfolioData(
            dayPnl: dayPnl,
            dayPnlPct: prevClose > 0 ? dayPnl / prevClose * 100 : 0,
            holdings: allHoldings
        )
    }
}
