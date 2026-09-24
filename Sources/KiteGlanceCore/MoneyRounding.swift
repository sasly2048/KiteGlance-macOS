import Foundation

/// Rounding rules shared by the macOS and Windows builds.
///
/// `Decimal` does not expose rounding mode in its API; `formatted(...)` uses
/// half-to-even by default. The Windows `Math.Round(... AwayFromZero)` rounds
/// half values *up* in absolute magnitude. The widget's display is its only
/// signal of P&L, so a row showing 0.5 on the rupee total rendering as
/// "₹0" here and "₹1" on Windows is a real (not cosmetic) divergence.
public enum MoneyRounding {
    /// Round half values away from zero. 0.5 -> 1, -0.5 -> -1, 1.5 -> 2.
    public static func halfAwayFromZero(_ value: Double) -> Double {
        value.rounded(.toNearestOrAwayFromZero)
    }

    /// Round half values away from zero at `places` decimal places.
    /// `halfAwayFromZero(12.345, places: 2)` -> 12.35. Callers that then
    /// format to fixed fractional precision (percent, Cr/L) need this:
    /// rounding to a whole number first throws away the digits they print.
    public static func halfAwayFromZero(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded(.toNearestOrAwayFromZero) / factor
    }

    /// True when the given Decimal is exactly a half value (`.5`) at the
    /// resolution of a `Double`. Used by tests to assert that the round-trip
    /// through `formatted` keeps the parity with Windows.
    public static func isExactlyHalf(_ value: Double) -> Bool {
        // The simplest check: the fractional part is exactly 0.5.
        value.truncatingRemainder(dividingBy: 1) == 0.5
    }
}
