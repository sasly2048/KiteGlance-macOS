import SwiftUI
import AppKit

/// Every colour the widget draws with, in one place, so a theme is a value
/// rather than a rewrite.
///
/// The label ladder (`primary` down to `faintest`) replaces the scattered
/// `Color.white` and `Color(white: 1, opacity: …)` literals. The opacities are
/// not mirrored between themes: black at 0.55 on white reads considerably
/// heavier than white at 0.55 on near-black did, so the light ladder is pulled
/// back at every rung. A mechanical inversion looks muddy and over-inked.
///
/// Lives in `KiteGlanceCore` so the palette-parity test in
/// `Tests/KiteGlanceTests/PaletteTests.swift` can reach both `Palette.dark`
/// and `Palette.light` directly. `XCTest` cannot import an executable
/// target, which is why the test target only depends on Core.
public struct Palette: Sendable {
    // Text and iconography, strongest to faintest.
    public let primary: Color
    public let secondary: Color
    public let tertiary: Color
    public let faint: Color
    public let faintest: Color

    /// Fills and hairlines drawn over the backdrop.
    public let surface: Color
    public let surfaceHover: Color
    public let hairline: Color

    /// Behind the settings pane and the connect/sign-in overlay.
    public let chrome: Color
    public let overlayScrim: Color
    public let toastBackground: Color

    public let positive: Color
    public let negative: Color
    /// A holding Kite has not priced yet -- deliberately muted, not coloured.
    public let unpriced: Color

    /// How strongly to wash the backdrop art toward the theme. The eight
    /// backdrops are dark-tuned raster images; in light mode they are tinted
    /// rather than replaced, because commissioning a second set of eight to
    /// serve a theme toggle is not a trade worth making.
    public let backdropTint: Color
    public let backdropTintOpacity: Double
    /// Grain is a dark-mode texture. Over a light wash it reads as dirt.
    public let grainOpacity: Double

    public let appearance: NSAppearance.Name

    public static let dark = Palette(
        primary: .white,
        secondary: Color(white: 1, opacity: 0.55),
        tertiary: Color(white: 1, opacity: 0.3),
        faint: Color(white: 1, opacity: 0.18),
        faintest: Color(white: 1, opacity: 0.08),
        surface: Color(white: 1, opacity: 0.05),
        surfaceHover: Color(white: 1, opacity: 0.07),
        hairline: Color(white: 1, opacity: 0.08),
        chrome: Color(white: 0.07, opacity: 0.72),
        overlayScrim: Color(white: 0.07, opacity: 0.95),
        toastBackground: Color(white: 0.14, opacity: 0.95),
        // systemGreen / systemRed, dark variants.
        positive: Color(red: 0x32/255, green: 0xD7/255, blue: 0x4B/255),
        negative: Color(red: 0xFF/255, green: 0x45/255, blue: 0x3A/255),
        unpriced: Color(white: 1, opacity: 0.3),
        backdropTint: .clear,
        backdropTintOpacity: 0,
        grainOpacity: 0.028,
        appearance: .darkAqua
    )

    /// Not an inversion of the above. The label opacities are lower at every
    /// rung, the accents are the light-mode system colours, and the backdrop is
    /// washed toward white instead of being replaced.
    public static let light = Palette(
        primary: Color(white: 0.08),
        secondary: Color(white: 0, opacity: 0.62),
        tertiary: Color(white: 0, opacity: 0.42),
        faint: Color(white: 0, opacity: 0.26),
        faintest: Color(white: 0, opacity: 0.1),
        surface: Color(white: 0, opacity: 0.04),
        surfaceHover: Color(white: 0, opacity: 0.06),
        hairline: Color(white: 0, opacity: 0.1),
        chrome: Color(white: 0.97, opacity: 0.8),
        overlayScrim: Color(white: 0.96, opacity: 0.95),
        toastBackground: Color(white: 0.99, opacity: 0.96),
        // systemGreen #32D74B -> #34C759 and systemRed #FF453A -> #FF3B30:
        // the dark variants are lifted for contrast against black and turn
        // fluorescent on white.
        positive: Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255),
        negative: Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255),
        unpriced: Color(white: 0, opacity: 0.42),
        backdropTint: .white,
        backdropTintOpacity: 0.82,
        grainOpacity: 0,
        appearance: .aqua
    )

    public static func of(_ theme: ResolvedTheme) -> Palette {
        theme == .dark ? .dark : .light
    }
}

public extension NSAppearance {
    /// Whether this appearance is one of the dark variants.
    ///
    /// `bestMatch` rather than a name comparison: the effective appearance may
    /// be `darkAqua`, `vibrantDark`, or a high-contrast variant of either, and
    /// only asking it to match against the two roots covers all of them.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
