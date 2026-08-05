import Foundation

/// Parses AMFI's NAVAll.txt.
///
/// Line format: `schemeCode;ISIN growth;ISIN reinvest;name;nav;date`
///
/// Pure and separate from the fetching service so the format can be tested
/// without a network round trip.
public struct NavParser {
    /// Skips headers, section titles, AMC names, and rows where the NAV is
    /// "N.A." or the ISIN is missing.
    public static func parse(_ text: String) -> [String: Decimal] {
        var map: [String: Decimal] = [:]
        map.reserveCapacity(20_000)

        text.enumerateLines { line, _ in
            // Data rows have five semicolons. Section headers and AMC names have
            // none. Cheap prefilter.
            guard line.count >= 20, line.contains(";"),
                  !line.hasPrefix("Scheme Code") else { return }

            let parts = line.split(separator: ";", maxSplits: 5, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { return }

            // AMFI publishes with a decimal point regardless of locale, so the
            // parse is pinned to POSIX rather than the user's locale -- in a
            // comma-decimal locale, "1.234" would otherwise read as 1234.
            let navText = parts[4].trimmingCharacters(in: .whitespaces)
            guard let nav = Decimal(string: navText, locale: Locale(identifier: "en_US_POSIX")),
                  nav > 0 else { return }

            // Two ISIN columns: growth (index 1) and reinvestment (index 2).
            // Kite's MF tradingsymbol can be either, so index both.
            let isinGrowth = parts[1].trimmingCharacters(in: .whitespaces)
            let isinReinvest = parts[2].trimmingCharacters(in: .whitespaces)

            if isinGrowth.count == 12 { map[isinGrowth] = nav }
            if isinReinvest.count == 12 { map[isinReinvest] = nav }
        }

        return map
    }
}
