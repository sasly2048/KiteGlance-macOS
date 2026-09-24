import Foundation
import SwiftUI
import KiteGlanceCore

/// A struct, not an `ObservableObject`. The old class minted a fresh `UUID` in
/// every initializer, and `holdingsViewModels` rebuilt the whole array on each
/// access -- so SwiftUI saw an entirely new identity set on every render and
/// threw away row animations and hover state. Value semantics plus the stable
/// `Holding.id` let the diffing algorithm recognise the same row across
/// refreshes.
struct HoldingViewModel: Identifiable, Equatable {
    let id: String
    let rawSymbol: String
    let qty: Decimal
    let avgPrice: Decimal
    let lastPrice: Decimal
    let isMutualFund: Bool
    let awaitingPrice: Bool
    let apiPnl: Decimal?

    let symbol: String

    init(holding: Holding) {
        self.id = holding.id
        self.rawSymbol = holding.symbol
        self.qty = holding.qty
        self.avgPrice = holding.avgPrice
        self.lastPrice = holding.lastPrice
        self.isMutualFund = holding.isMutualFund
        self.awaitingPrice = holding.awaitingPrice
        self.apiPnl = holding.apiPnl
        self.symbol = Money.prettyName(holding.symbol)
    }

    var invested: Decimal { PnlMath.invested(qty: qty, avgPrice: avgPrice) }
    var pnl: Decimal { PnlMath.pnl(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice, apiPnl: apiPnl, awaitingPrice: awaitingPrice) }
    var current: Decimal { PnlMath.current(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice, apiPnl: apiPnl, awaitingPrice: awaitingPrice) }
    var pnlPct: Decimal { PnlMath.pnlPct(pnl: pnl, invested: invested) }

    var pnlDisplay: String {
        awaitingPrice ? "--" : Money.signed(pnl)
    }

    var returnDisplay: String {
        awaitingPrice ? "not priced yet" : Money.percent(pnlPct)
    }

    var investedDisplay: String { Money.rupees(invested) }
    var currentDisplay: String { Money.rupees(current) }

    var tooltip: String {
        "\(rawSymbol)\n\(qty.formatted(.number.precision(.fractionLength(3)))) units at \(Money.exact(avgPrice))"
        + (awaitingPrice
            ? "\nNot priced by Kite yet - held at cost"
            : "\nNow \(Money.exact(lastPrice))")
        + "\n\nClick to copy symbol"
    }

    /// Takes the palette rather than baking a colour in at init: the same row
    /// is drawn in either theme, and the accents differ between them.
    func pnlColor(_ palette: Palette) -> Color {
        if awaitingPrice { return palette.unpriced }
        return pnl >= 0 ? palette.positive : palette.negative
    }

    /// One sentence for VoiceOver, in place of four loose numbers.
    var accessibilityValue: String {
        if awaitingPrice {
            return "\(Money.rupees(invested)) invested. Not priced by Kite yet."
        }
        let direction = pnl >= 0 ? "up" : "down"
        return "\(Money.rupees(invested)) invested, now worth \(Money.rupees(current)). "
            + "\(direction) \(Money.rupees(abs(pnl))), \(Money.percent(pnlPct))."
    }
}

@MainActor
class PortfolioViewModel: ObservableObject {
    @Published var portfolio: PortfolioData? { didSet { rebuildHoldings() } }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastSync: Date?
    /// Bumped by `attemptManualRefresh` only when a refresh actually fires;
    /// the toast "Just synced a moment ago" reads from this so a user
    /// who hits `R` twice in a second sees the throttle message, not a
    /// second refresh. Mirrors the Windows `_lastManual` from the
    /// `RefreshAsync` 60-second cooldown.
    @Published var lastManualSync: Date?
    @Published var usingStaleNavs = false
    @Published var expanded = false
    @Published var activeTab = "stocks" { didSet { rebuildHoldings() } }

    /// Index of the currently keyboard-focused row in the holdings list.
    /// `nil` when the list is not focused. The arrow keys move this up and
    /// down; `Enter` copies the row's ticker to the clipboard (matching
    /// the Windows ListBox behaviour). Resets to `nil` whenever the visible
    /// holdings change shape (tab switch, refresh that adds/drops rows).
    @Published var selectedRowIndex: Int? = nil
    @Published var showOverlay = false
    /// One-shot toast text pushed by the window controller (manual-refresh
    /// throttle notice, "Copied SYMBOL"). WidgetView observes this and clears
    /// it back to nil after showing. Previously the controller wrote to a
    /// `toastMessage` that only existed as WidgetView-local @State, so the
    /// writes did not compile and the toasts never rendered.
    @Published var toastMessage: String?
    @Published var overlayTitle = ""
    @Published var overlayBody = ""
    @Published var overlayActionTitle = ""
    /// True while a login round-trip is in flight, so the overlay button can be
    /// disabled rather than starting a second login server on the same port.
    @Published var isSigningIn = false
    /// Bumped by the controller's 20-second timer. `syncLabel` and the backdrop
    /// are computed from the wall clock, so something observable has to change
    /// for SwiftUI to recompute them.
    @Published var clockTick: UInt64 = 0
    var overlayAction: (() -> Void)?

    var stocks: [Holding] {
        portfolio?.holdings.filter { !$0.isMutualFund } ?? []
    }

    var funds: [Holding] {
        portfolio?.holdings.filter { $0.isMutualFund } ?? []
    }

    var currentHoldings: [Holding] {
        activeTab == "funds" ? funds : stocks
    }

    /// Rebuilt only when the portfolio or tab actually changes. As a computed
    /// property this re-sorted and re-allocated the whole list on every access,
    /// and it is read from both the SwiftUI body and the window-resize math --
    /// several times per frame.
    private(set) var holdingsViewModels: [HoldingViewModel] = []

    private func rebuildHoldings() {
        holdingsViewModels = currentHoldings
            .sorted { abs($0.pnl) > abs($1.pnl) }
            .map(HoldingViewModel.init(holding:))
        // A refresh can add or drop rows; the previous selection is now
        // meaningless. Clamp to the new count, or nil it out if there
        // are no rows left, so the arrow keys don't reach past the end.
        if let i = selectedRowIndex {
            if holdingsViewModels.isEmpty {
                selectedRowIndex = nil
            } else {
                selectedRowIndex = min(i, holdingsViewModels.count - 1)
            }
        }
    }

    var invested: Decimal {
        currentHoldings.reduce(0) { $0 + $1.invested }
    }

    var overallPnl: Decimal {
        currentHoldings.reduce(0) { $0 + $1.pnl }
    }

    var currentValue: Decimal {
        invested + overallPnl
    }

    var heroValue: Decimal {
        activeTab == "funds" ? overallPnl : (portfolio?.dayPnl ?? 0)
    }

    var heroPct: Decimal {
        activeTab == "funds"
            ? (invested > 0 ? overallPnl / invested * 100 : 0)
            : (portfolio?.dayPnlPct ?? 0)
    }

    var heroLabel: String {
        activeTab == "funds" ? "Overall" : "Today"
    }

    /// Hero percentage rendered with AwayFromZero rounding to match Windows.
    /// The bare `Decimal.formatted(...)` defaults to half-to-even, so a value
    /// of 0.005% rounds to "0.00%" on macOS but "0.01%" on Windows. The
    /// hero percent is a single character of disagreement per row per refresh
    /// in the worst case, but `Money.percent` is already the canonical
    /// formatter for these values -- use it here too.
    var heroPctDisplay: String {
        Money.percent(heroPct)
    }

    func heroColor(_ palette: Palette) -> Color {
        heroValue >= 0 ? palette.positive : palette.negative
    }

    /// Recent price windows, keyed by raw symbol, for the row sparklines.
    @Published var priceHistory: PriceHistory = PriceHistory()

    /// The market-open pulse is an animation, which VoiceOver cannot perceive at
    /// all. This is the same fact in words.
    var marketStatusDescription: String {
        isMarketOpen ? "Market open" : "Market closed"
    }

    /// The hero figure as a sentence, so the largest number on the widget is not
    /// announced as a bare amount with no indication of what it measures.
    var heroAccessibilityValue: String {
        let direction = heroValue >= 0 ? "up" : "down"
        return "\(direction) \(Money.rupees(abs(heroValue))), \(Money.percent(heroPct))"
    }

    /// NSE cash session: Mon-Fri, 09:15-15:30 IST. Explicitly Gregorian --
    /// `Calendar.current` follows the user's locale, and a non-Gregorian
    /// calendar numbers weekdays differently, so `weekday != 1 && weekday != 7`
    /// would silently stop meaning "not a weekend".
    var isMarketOpen: Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let components = cal.dateComponents([.weekday, .hour, .minute], from: Date())

        guard let weekday = components.weekday, weekday != 1 && weekday != 7 else { return false }
        guard let hour = components.hour, let minute = components.minute else { return false }
        let minutes = hour * 60 + minute
        // Session is [09:15, 15:30): the close is AT 15:30:00, so the 15:30
        // minute is closed (was `<= 15*60 + 30`, a one-minute over-count).
        return minutes >= 9*60 + 15 && minutes < 15*60 + 30
    }

    var syncLabel: String {
        guard let lastSync else { return "" }

        let diff = Date().timeIntervalSince(lastSync)
        let base: String
        if diff < 45 { base = "just now" }
        else if diff < 3600 { base = "\(Int(diff/60))m ago" }
        else if diff < 21600 { base = "\(Int(diff/3600))h ago" }
        else {
            let fmt = DateFormatter()
            fmt.timeZone = TimeZone(identifier: "Asia/Kolkata")
            fmt.dateFormat = "h:mm a"
            base = "at \(fmt.string(from: lastSync).lowercased())"
        }

        // A failed fetch with a previous successful sync is "stale" rather
        // than empty: the user has a portfolio on screen, but the next
        // refresh did not land. Prefix the label so they know the data is
        // not current -- matches the Windows "stale" sync label.
        if errorMessage != nil {
            return "stale  ·  \(base)"
        }
        if usingStaleNavs {
            return "\(base)  ·  fund NAVs delayed"
        }
        return base
    }

    /// `true` when the most recent refresh failed and we still have stale data
    /// on screen. Drives the amber "Cannot reach Kite" dot color in
    /// `WidgetView`. A fresh launch with no portfolio yet is `false` -- the
    /// connect overlay already conveys that state.
    var isStale: Bool {
        errorMessage != nil && portfolio != nil
    }

    /// The action is required, not optional. `overlayAction` was previously
    /// declared but never assigned by either of these, so the only button on the
    /// first-launch screen did nothing and a new user could not set the app up
    /// at all. The Windows original passes the callback into `ShowOverlay` at
    /// every call site; making it a required parameter means the compiler
    /// enforces that.
    func showConnectOverlay(onAction: @escaping () -> Void) {
        presentOverlay(
            title: "Connect Kite",
            body: "Add your Kite Connect API key and secret to begin.",
            actionTitle: "Set up",
            action: onAction
        )
    }

    func showLoginOverlay(reason: String? = nil, onAction: @escaping () -> Void) {
        presentOverlay(
            title: "Sign in",
            body: reason ?? "Kite sessions reset each morning. Sign in to sync today's portfolio.",
            actionTitle: "Sign in with Kite",
            action: onAction
        )
    }

    /// Named `presentOverlay`, not `showOverlay`: the latter is already a
    /// `@Published var` on this type.
    private func presentOverlay(title: String, body: String, actionTitle: String, action: @escaping () -> Void) {
        overlayTitle = title
        overlayBody = body
        overlayActionTitle = actionTitle
        overlayAction = action
        showOverlay = true
    }

    func hideOverlay() { showOverlay = false }

    /// Throttles a manual refresh request to once per minute.
    ///
    /// Returns `true` when the throttle passed and the caller should fire a
    /// fetch; `false` when the user hit the button too soon and the toast
    /// should already be on screen. The Windows `RefreshAsync` has the
    /// same 60-second cooldown; the toast text is identical to keep the
    /// platforms consistent.
    static let manualCooldown: TimeInterval = 60
    /// Where the controller reads "is the user allowed to refresh right
    /// now?" Returns `true` when enough time has passed since the last
    /// manual sync, or no manual sync has happened yet.
    func canRefreshManually(now: Date = Date()) -> Bool {
        guard let last = lastManualSync else { return true }
        return now.timeIntervalSince(last) >= Self.manualCooldown
    }
}