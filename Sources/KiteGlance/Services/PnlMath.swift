import Foundation

struct PnlMath {
    static func invested(qty: Decimal, avgPrice: Decimal) -> Decimal {
        qty * avgPrice
    }

    static func pnl(qty: Decimal, avgPrice: Decimal, lastPrice: Decimal, apiPnl: Decimal?, awaitingPrice: Bool) -> Decimal {
        if awaitingPrice { return 0 }
        if let apiPnl, apiPnl != 0 { return apiPnl }
        return (lastPrice - avgPrice) * qty
    }

    static func current(qty: Decimal, avgPrice: Decimal, lastPrice: Decimal, apiPnl: Decimal?, awaitingPrice: Bool) -> Decimal {
        if awaitingPrice { return invested(qty: qty, avgPrice: avgPrice) }
        if let apiPnl, apiPnl != 0 { return invested(qty: qty, avgPrice: avgPrice) + apiPnl }
        return qty * lastPrice
    }

    static func pnlPct(pnl: Decimal, invested: Decimal) -> Decimal {
        invested > 0 ? pnl / invested * 100 : 0
    }

    static func kiteReportedPnl(_ apiPnl: Decimal?) -> Bool {
        apiPnl != nil && apiPnl != 0
    }
}