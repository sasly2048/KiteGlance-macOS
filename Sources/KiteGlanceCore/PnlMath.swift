import Foundation

/// The profit-and-loss arithmetic for a single holding, in one pure, UI-free,
/// side-effect-free place.
///
/// It lives on its own for two reasons. First, it is the most consequential
/// logic in the app, so it earns a home where it can be unit tested in
/// isolation, with no AppKit or network in the way. Second, keeping it pure
/// means the same code runs in the widget and in the test suite: the tests
/// verify what actually ships, not a paraphrase of it.
public struct PnlMath {
    /// Whether Kite genuinely reported a P&L for this holding.
    ///
    /// The MF endpoint returns `pnl: 0` -- a literal zero, not null -- for
    /// holdings it has not computed. Treating that as authoritative zeroes out
    /// real money: every row reads +₹0 and current collapses onto invested. A
    /// zero from an API that also reports a moving NAV is not a fact; it is an
    /// absence wearing a number's clothes. So a reported P&L counts only when it
    /// is present AND non-zero.
    public static func kiteReportedPnl(_ apiPnl: Decimal?) -> Bool {
        guard let apiPnl else { return false }
        return apiPnl != 0
    }

    /// Amount put in: quantity times the average buy price.
    public static func invested(qty: Decimal, avgPrice: Decimal) -> Decimal {
        qty * avgPrice
    }

    /// Profit or loss. Kite's own figure when it gave us one; otherwise
    /// (last - avg) * qty, which reproduces Coin's numbers exactly. When Kite
    /// has not priced the units yet they are held at cost, so zero.
    public static func pnl(
        qty: Decimal, avgPrice: Decimal, lastPrice: Decimal,
        apiPnl: Decimal?, awaitingPrice: Bool
    ) -> Decimal {
        if awaitingPrice { return 0 }
        if kiteReportedPnl(apiPnl) { return apiPnl! }
        return (lastPrice - avgPrice) * qty
    }

    /// Current value, kept consistent with `pnl` by construction so a row can
    /// never show a current value that contradicts its own P&L: when we take
    /// Kite's P&L, current is invested + that P&L; when we compute P&L from the
    /// NAV, current is qty * last_price.
    public static func current(
        qty: Decimal, avgPrice: Decimal, lastPrice: Decimal,
        apiPnl: Decimal?, awaitingPrice: Bool
    ) -> Decimal {
        if awaitingPrice { return invested(qty: qty, avgPrice: avgPrice) }
        if kiteReportedPnl(apiPnl) { return invested(qty: qty, avgPrice: avgPrice) + apiPnl! }
        return qty * lastPrice
    }

    /// P&L as a percentage of invested. Zero when nothing is invested.
    public static func pnlPct(pnl: Decimal, invested: Decimal) -> Decimal {
        invested > 0 ? pnl / invested * 100 : 0
    }
}
