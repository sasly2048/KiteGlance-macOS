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
            // Data rows have at least five semicolons. Section headers and AMC
            // names have none. Cheap prefilter.
            guard line.count >= 20, line.contains(";"),
                  !line.hasPrefix("Scheme Code") else { return }

            // Split on every semicolon rather than capping the count. Fund
            // names contain them -- "... Fund; Growth Option" -- and a capped
            // split left the name's tail glued to the NAV and the date, so
            // index 4 held " Growth Option" instead of a number. The Decimal
            // parse then failed and the guard below dropped the fund from the
            // map entirely, silently falling back to Kite's stale NAV for it.
            let parts = line.split(separator: ";", omittingEmptySubsequences: false)

            // Six fields minimum: code, two ISINs, name, NAV, date. A shorter
            // row cannot be a data row, and admitting five would read the date
            // where the NAV is expected.
            guard parts.count >= 6 else { return }

            // Counted from the end, so extra semicolons inside the name shift
            // the name's own fields rather than the NAV's position. The date is
            // last; the NAV immediately precedes it.
            //
            // AMFI publishes with a decimal point regardless of locale, so the
            // parse is pinned to POSIX rather than the user's locale -- in a
            // comma-decimal locale, "1.234" would otherwise read as 1234.
            let navText = parts[parts.count - 2].trimmingCharacters(in: .whitespaces)
            guard let nav = Decimal(string: navText, locale: Locale(identifier: "en_US_POSIX")),
                  nav > 0 else { return }

            // Two ISIN columns: growth (index 1) and reinvestment (index 2).
            // Kite's MF tradingsymbol can be either, so index both. These stay
            // counted from the start: only the name can contain a separator, so
            // nothing before it can be displaced.
            let isinGrowth = parts[1].trimmingCharacters(in: .whitespaces)
            let isinReinvest = parts[2].trimmingCharacters(in: .whitespaces)

            if isinGrowth.count == 12 { map[isinGrowth] = nav }
            if isinReinvest.count == 12 { map[isinReinvest] = nav }
        }

        return map
    }
}
