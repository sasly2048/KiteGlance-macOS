import Foundation

/// Currency, percent, and rupee formatting for the widget. Lives in
/// `KiteGlanceCore` so the test target can exercise it directly: the
/// previous home in the executable target meant the formatter was only
/// exercised through the view layer, which made regression fixes
/// (e.g. the half-away-from-zero rounding bug) hard to pin with a
/// focused test.
///
/// The unicode characters here (`₹`, `−`) are not Mac-only -- the
/// formatter is a `Decimal` -> `String` function with no AppKit
/// dependencies, and the same code can run on iOS or Linux Swift.
public enum Money {
    public static let rs = "₹"
    public static let minus = "−"

    /// `₹1,234` for a 4-digit amount, `₹1.23Cr` for >= 10,000,000, and
    /// `₹1234.56` for sub-1,000 amounts (the only place we keep paise).
    /// All branches round half-away-from-zero, matching the Windows
    /// `Money.Rupees` so a `₹999.5` on one platform is `₹1,000` on the
    /// other and not `₹999` here / `₹1,000` there.
    public static func rupees(_ value: Decimal) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? minus : ""

        // Cast to Double for the formatted rounding, then format with the
        // desired precision. Casting back to Decimal after `rounded(...)` is
        // not necessary because the formatter only reads the magnitude.
        let d = absValue.doubleValue

        if absValue >= 10_000_000 {
            let v = MoneyRounding.halfAwayFromZero(d / 10_000_000, places: 2)
            return "\(sign)\(rs)\(v.formatted(.number.precision(.fractionLength(2))))Cr"
        } else if absValue >= 100_000 {
            let v = MoneyRounding.halfAwayFromZero(d / 100_000, places: 2)
            return "\(sign)\(rs)\(v.formatted(.number.precision(.fractionLength(2))))L"
        } else if absValue >= 1_000 {
            // The >= 1_000 path shows whole rupees. Round half up here too:
            // a rupee total of 999.5 (the half-paisa rounding noise from Kite's
            // pnl field) should show "₹1,000" on both platforms, not "₹1,000"
            // here and "₹999" on Windows.
            let v = MoneyRounding.halfAwayFromZero(d)
            return "\(sign)\(rs)\(v.formatted(.number.grouping(.automatic).precision(.fractionLength(0))))"
        } else {
            return "\(sign)\(rs)\(d.formatted(.number.precision(.fractionLength(2))))"
        }
    }

    /// Like `rupees` but always prefixes a sign, so a positive number reads
    /// `+₹1,234` and a negative reads `−₹1,234`. Used for per-row P&L
    /// where the direction is part of the value.
    public static func signed(_ value: Decimal) -> String {
        let prefix = value >= 0 ? "+" : minus
        return "\(prefix)\(rupees(abs(value)))"
    }

    /// `+12.34%` style. Half-away-from-zero so a half-paisa return rounds
    /// up on both platforms.
    public static func percent(_ value: Decimal) -> String {
        let prefix = value >= 0 ? "+" : minus
        let d = abs(value).doubleValue
        return "\(prefix)\(MoneyRounding.halfAwayFromZero(d, places: 2).formatted(.number.precision(.fractionLength(2))))%"
    }

    /// `₹1,234.56` -- the un-rounded, un-signed, un-abbreviated rupee
    /// figure, used in tooltips where the widget cannot afford to lose
    /// a half-paisa.
    public static func exact(_ value: Decimal) -> String {
        let d = value.doubleValue
        return "\(rs)\(d.formatted(.number.grouping(.automatic).precision(.fractionLength(2))))"
    }

    /// Lives in `KiteGlanceCore` so it can be unit tested without AppKit.
    public static func prettyName(_ raw: String) -> String {
        FundNameFormatter.prettyName(raw)
    }
}

extension Decimal {
    /// The `Decimal` -> `Double` cast used throughout the Money formatters.
    /// A lossy step for very large `Decimal`s, but the widget's display
    /// is in crores (1e7) at the top end, which fits in `Double`'s
    /// 53-bit mantissa to the rupee.
    public var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
