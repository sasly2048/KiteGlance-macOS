import Foundation
import KiteGlanceCore
import os.log

/// Keeps a short price history per symbol so each row can draw a sparkline.
///
/// Two sources, in preference order. Kite's `/instruments/historical` gives a
/// real intraday curve, but it is a *paid* subscription -- most accounts get a
/// 403 for it, which is a normal answer here and not an error worth surfacing.
/// So the fallback is to accumulate what every refresh already fetches: the
/// last price, appended to a rolling ~40-point series on disk. That costs no
/// extra API calls and works on every account.
///
/// Mutual funds use the local series only. There is no historical instrument
/// token for a fund, and one NAV a day would take six weeks to fill a chart.
actor PriceHistoryService {
    private let logger = Logger(subsystem: "com.kiteglance", category: "PriceHistory")
    private let fileName: String
    private var history: PriceHistory
    private var didLoad = false

    /// Set once this account is known to lack the historical subscription.
    ///
    /// Deliberately one flag for the whole service rather than a per-symbol set:
    /// the subscription is an account-level entitlement, so a `PermissionException`
    /// for one instrument means every instrument will refuse too. One 403 per
    /// launch is the most this should ever cost.
    private var historicalUnavailable = false

    init(fileName: String = "price-history.json") {
        self.fileName = fileName
        self.history = PriceHistory()
    }

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KiteGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            history = try JSONDecoder().decode(PriceHistory.self, from: data)
        } catch {
            // A sparkline is not worth a crash, but a half-written file that
            // silently throws away the last few days of price points is worth
            // a line in the log so "the sparkline is gone" has a cause. The
            // Windows fix #29 added an equivalent warn for the same reason.
            logger.warning("history.json unreadable (\(error.localizedDescription, privacy: .public)); sparklines will restart")
        }
    }

    /// Folds this refresh's prices in and persists the result.
    ///
    /// Called with every holding on every refresh; `PriceSeries.append` is what
    /// decides whether a given price is worth keeping.
    func record(_ prices: [(symbol: String, price: Decimal)]) {
        loadIfNeeded()

        for entry in prices {
            history.record(symbol: entry.symbol, price: entry.price.doubleValue)
        }

        // A sold position should not keep its history on disk forever.
        history.prune(keeping: Set(prices.map(\.symbol)))
        persist()
    }

    func series(for symbol: String) -> PriceSeries {
        loadIfNeeded()
        return history[symbol]
    }

    func allSeries() -> PriceHistory {
        loadIfNeeded()
        return history
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Whether this symbol still wants seeding from the historical endpoint.
    ///
    /// Asked before the fetch so the caller can skip the network entirely for
    /// rows the local accumulation has already filled, and for every row once
    /// the account is known not to subscribe.
    func needsHistoricalSeed(symbol: String) -> Bool {
        loadIfNeeded()
        return !historicalUnavailable && !history[symbol].isRenderable
    }

    /// Records that this account has no historical subscription, so the endpoint
    /// is asked at most once per launch.
    func markHistoricalUnavailable() {
        historicalUnavailable = true
    }

    /// Seeds a symbol from closes already fetched by the caller.
    ///
    /// Takes `[Double]` rather than a fetching closure: a closure is not
    /// `Sendable`, so under Swift 6 it cannot cross into this actor. The caller
    /// owns the HTTP anyway, so handing over plain data is both simpler and the
    /// only thing that compiles.
    func seed(symbol: String, closes: [Double]) {
        loadIfNeeded()

        guard !closes.isEmpty, !history[symbol].isRenderable else { return }

        var series = PriceSeries()
        for close in closes { series.append(close) }
        history.series[symbol] = series
        persist()
    }

    /// Seeds from a dense intraday feed. The caller is expected to have
    /// down-sampled to the sparkline width; this method marks the symbol
    /// frozen so per-refresh `record` calls do not pile a single non-aligned
    /// `last_price` on the right edge of a 5-minute-candle chart.
    ///
    /// Mirrors the Windows `SeedIntraday`: replace the (possibly
    /// locally-accumulated) series with the down-sampled feed and freeze it.
    /// A first-time seed on a brand-new series skips the `record` step
    /// because there is no pre-existing data to lose.
    func seedIntraday(symbol: String, downsampledCloses: [Double]) {
        loadIfNeeded()
        guard !downsampledCloses.isEmpty else { return }
        history.seedIntraday(symbol: symbol, closes: downsampledCloses)
        persist()
    }
}
