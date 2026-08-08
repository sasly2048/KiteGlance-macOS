import Foundation

/// What the user asked for. Distinct from what is actually shown: `.system`
/// resolves against the OS appearance at render time.
public enum ThemeMode: String, CaseIterable, Codable, Sendable {
    case system = "Match System"
    case dark = "Dark"
    case light = "Light"
}

/// The appearance actually in force.
public enum ResolvedTheme: String, Sendable {
    case dark, light

    /// `.system` defers to the OS; the explicit modes override it. Kept pure and
    /// separate from SwiftUI so the resolution rule is unit testable -- the
    /// `Environment(\.colorScheme)` value is simply passed in.
    public static func resolve(mode: ThemeMode, systemIsDark: Bool) -> ResolvedTheme {
        switch mode {
        case .dark: .dark
        case .light: .light
        case .system: systemIsDark ? .dark : .light
        }
    }
}
