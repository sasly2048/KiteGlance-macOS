import Foundation
import CoreGraphics

/// A rolling window of recent prices for one symbol, used to draw its sparkline.
///
/// Pure value logic: appending, trimming and normalising all live here so they
/// can be unit tested, while `PriceHistoryService` in the app target owns the
/// disk and the network.
public struct PriceSeries: Codable, Equatable, Sendable {
    /// Roughly 40 points is what the row is wide enough to resolve. Older
    /// samples fall off the front.
    public static let capacity = 40

    public private(set) var points: [Double]

    public init(points: [Double] = []) {
        self.points = Array(points.suffix(Self.capacity))
    }

    /// Records a price, unless it repeats the one before it.
    ///
    /// The skip is not a cosmetic de-duplication; it is what keeps the chart
    /// alive across a closed market. A 5-minute refresh over a weekend appends
    /// ~576 samples, every one of them the same Friday close. Without this
    /// guard those identical values evict all 40 real points, and the sparkline
    /// is a dead flat line at exactly the moment the market reopens and the
    /// user looks at it. Storing only *changes* means a quiet market simply
    /// leaves the previous shape standing.
    public mutating func append(_ price: Double) {
        guard price > 0 else { return }
        if let last = points.last, last == price { return }

        points.append(price)
        if points.count > Self.capacity {
            points.removeFirst(points.count - Self.capacity)
        }
    }

    /// Fewer than two distinct points cannot describe a line.
    public var isRenderable: Bool { points.count >= 2 }

    /// Whether the series itself ends higher than it started.
    ///
    /// Deliberately the series' own direction, not the holding's total P&L: the
    /// line is a picture of the recent window it draws, so a stock still down
    /// overall but recovering today shows a rising green line. Colouring it by
    /// lifetime P&L would contradict the shape immediately above it.
    public var isRising: Bool {
        guard let first = points.first, let last = points.last else { return true }
        return last >= first
    }

    /// Points mapped into a 0...1 box, scaled against this series' own min and
    /// max so each row uses its full height regardless of share price. A flat
    /// series sits on the mid-line rather than dividing by a zero range.
    public func normalised() -> [CGPoint] {
        guard isRenderable else { return [] }

        let lo = points.min() ?? 0
        let hi = points.max() ?? 0
        let range = hi - lo
        let lastIndex = Double(points.count - 1)

        return points.enumerated().map { index, value in
            CGPoint(
                x: Double(index) / lastIndex,
                // y is flipped here: callers draw in view space, where y grows
                // downward, so the highest price must map to 0.
                y: range > 0 ? 1 - ((value - lo) / range) : 0.5
            )
        }
    }
}

/// Every symbol's series, as persisted.
public struct PriceHistory: Codable, Equatable, Sendable {
    public var series: [String: PriceSeries]

    public init(series: [String: PriceSeries] = [:]) {
        self.series = series
    }

    public subscript(symbol: String) -> PriceSeries {
        series[symbol] ?? PriceSeries()
    }

    public mutating func record(symbol: String, price: Double) {
        var existing = series[symbol] ?? PriceSeries()
        existing.append(price)
        series[symbol] = existing
    }

    /// Drops series for symbols no longer held, so a sold position does not keep
    /// its history on disk forever.
    public mutating func prune(keeping symbols: Set<String>) {
        series = series.filter { symbols.contains($0.key) }
    }
}
