import Foundation

/// Turns Kite's shouty scheme names ("HDFC MID-CAP OPPORTUNITIES FUND - DIRECT
/// PLAN - GROWTH") into something that fits a 372-point widget row
/// ("HDFC Mid-cap Opportunities Fund"). Pure string work, so it is tested
/// directly.
public struct FundNameFormatter {
    /// Tickers and acronyms that must stay uppercase; title-casing them would
    /// read as a typo.
    private static let keepUpper: Set<String> = [
        "HDFC", "ICICI", "SBI", "UTI", "ETF", "FOF", "NAV", "IT", "PSU", "FMCG",
        "NIFTY", "BSE", "NSE", "IDFC", "DSP", "PGIM", "LIC", "AMC", "REIT",
        "US", "UK", "GDP", "IPO", "ELSS", "NFO", "TATA", "L&T", "HSBC", "JM",
        "IDCW", "G-SEC", "SENSEX"
    ]

    /// Ordered (pattern, replacement) pairs. The plan/option suffixes carry no
    /// information at a glance -- every holding has one -- so they are dropped.
    private static let substitutions: [(pattern: String, replacement: String)] = [
        (#"\s*[-\u{2013}]?\s*(DIRECT|REGULAR)\s+PLAN\b"#, ""),
        (#"\s*[-\u{2013}]?\s*(GROWTH|IDCW|DIVIDEND)(\s+OPTION)?\b"#, ""),
        (#"\bFUND OF FUND\b"#, "FoF"),
        (#"\s*[-\u{2013}]\s*$"#, ""),
        // Collapse to a single space, not to "" -- the latter welded words
        // together ("HDFC  Top 100" became "HDFCTop 100").
        (#"\s{2,}"#, " ")
    ]

    public static func prettyName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "Unnamed" }

        for (pattern, replacement) in substitutions {
            s = s.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "Unnamed" }

        return s.split(separator: " ").map { word -> String in
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "()-,"))
            guard !bare.isEmpty else { return String(word) }

            if keepUpper.contains(bare.uppercased()) {
                return bare.uppercased()
            }
            if bare.count <= 2 && bare.allSatisfy({ $0.isUppercase }) {
                return bare.uppercased()
            }
            if bare.count == 1 {
                return bare.uppercased()
            }
            return bare.prefix(1).uppercased() + bare.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
