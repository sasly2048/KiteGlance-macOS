import Foundation
import SwiftUI

extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

struct Money {
    static let rs = "₹"
    static let minus = "−"

    static func rupees(_ value: Decimal) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? minus : ""

        if absValue >= 10_000_000 {
            return "\(sign)\(rs)\((absValue / 10_000_000).formatted(.number.precision(.fractionLength(2))))Cr"
        } else if absValue >= 100_000 {
            return "\(sign)\(rs)\((absValue / 100_000).formatted(.number.precision(.fractionLength(2))))L"
        } else if absValue >= 1_000 {
            return "\(sign)\(rs)\(absValue.formatted(.number.grouping(.automatic).precision(.fractionLength(0))))"
        } else {
            return "\(sign)\(rs)\(absValue.formatted(.number.precision(.fractionLength(2))))"
        }
    }

    static func signed(_ value: Decimal) -> String {
        let prefix = value >= 0 ? "+" : minus
        return "\(prefix)\(rupees(abs(value)))"
    }

    static func percent(_ value: Decimal) -> String {
        let prefix = value >= 0 ? "+" : minus
        return "\(prefix)\(abs(value).formatted(.number.precision(.fractionLength(2))))%"
    }

    static func exact(_ value: Decimal) -> String {
        "\(rs)\(value.formatted(.number.grouping(.automatic).precision(.fractionLength(2))))"
    }

    static func prettyName(_ raw: String) -> String {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "Unnamed" }

        var s = raw.trimmingCharacters(in: .whitespaces)

        // Ordered (pattern, replacement) pairs. The old version decided the
        // replacement by testing the *pattern* string for "FUND OF FUND", and
        // collapsed `\s{2,}` to "" instead of " " -- which welded words
        // together ("HDFC  Top 100" became "HDFCTop 100").
        let substitutions: [(pattern: String, replacement: String)] = [
            (#"\s*[-\u{2013}]?\s*(DIRECT|REGULAR)\s+PLAN\b"#, ""),
            (#"\s*[-\u{2013}]?\s*(GROWTH|IDCW|DIVIDEND)(\s+OPTION)?\b"#, ""),
            (#"\bFUND OF FUND\b"#, "FoF"),
            (#"\s*[-\u{2013}]\s*$"#, ""),
            (#"\s{2,}"#, " ")
        ]

        for (pattern, replacement) in substitutions {
            s = s.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        s = s.trimmingCharacters(in: .whitespaces)

        let keepUpper = Set([
            "HDFC", "ICICI", "SBI", "UTI", "ETF", "FOF", "NAV", "IT", "PSU", "FMCG",
            "NIFTY", "BSE", "NSE", "IDFC", "DSP", "PGIM", "LIC", "AMC", "REIT",
            "US", "UK", "GDP", "IPO", "ELSS", "NFO", "TATA", "L&T", "HSBC", "JM",
            "IDCW", "G-SEC", "SENSEX"
        ])

        return s.split(separator: " ").map { word in
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "()-,"))
            if keepUpper.contains(bare.uppercased()) || (bare.count <= 2 && bare.allSatisfy({ $0.isUppercase })) {
                return bare.uppercased()
            } else if bare.count == 1 {
                return bare.uppercased()
            } else {
                return bare.prefix(1).uppercased() + bare.dropFirst().lowercased()
            }
        }.joined(separator: " ")
    }
}

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
    let pnlColor: Color

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
        self.pnlColor = Self.color(for: holding)
    }

    var invested: Decimal { PnlMath.invested(qty: qty, avgPrice: avgPrice) }
    var pnl: Decimal { PnlMath.pnl(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice, apiPnl: apiPnl, awaitingPrice: awaitingPrice) }
    var current: Decimal { PnlMath.current(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice, apiPnl: apiPnl, awaitingPrice: awaitingPrice) }
    var pnlPct: Decimal { PnlMath.pnlPct(pnl: pnl, invested: invested) }

    var pnlDisplay: String {
        awaitingPrice ? "−−" : Money.signed(pnl)
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

    static func color(for holding: Holding) -> Color {
        if holding.awaitingPrice { return Color(white: 1, opacity: 0.3) }
        return holding.pnl >= 0 ? Color(red: 0x32/255, green: 0xD7/255, blue: 0x4B/255) : Color(red: 0xFF/255, green: 0x45/255, blue: 0x3A/255)
    }
}

@MainActor
class PortfolioViewModel: ObservableObject {
    @Published var portfolio: PortfolioData? { didSet { rebuildHoldings() } }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastSync: Date?
    @Published var usingStaleNavs = false
    @Published var expanded = false
    @Published var activeTab = "stocks" { didSet { rebuildHoldings() } }
    @Published var showOverlay = false
    @Published var overlayTitle = ""
    @Published var overlayBody = ""
    @Published var overlayActionTitle = ""
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

    var heroColor: Color {
        heroValue >= 0 ? Color(red: 0x32/255, green: 0xD7/255, blue: 0x4B/255) : Color(red: 0xFF/255, green: 0x45/255, blue: 0x3A/255)
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
        return minutes >= 9*60 + 15 && minutes <= 15*60 + 30
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

        if usingStaleNavs {
            return "\(base)  ·  fund NAVs delayed"
        }
        return base
    }

    func showConnectOverlay() {
        overlayTitle = "Connect Kite"
        overlayBody = "Add your Kite Connect API key and secret to begin."
        overlayActionTitle = "Set up"
        showOverlay = true
    }

    func showLoginOverlay(reason: String? = nil) {
        overlayTitle = "Sign in"
        overlayBody = reason ?? "Kite sessions reset each morning. Sign in to sync today's portfolio."
        overlayActionTitle = "Sign in with Kite"
        showOverlay = true
    }

    func hideOverlay() { showOverlay = false }
}