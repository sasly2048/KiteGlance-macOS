import SwiftUI
import AppKit
import KiteGlanceCore

/// Every colour the widget draws with, in one place, so a theme is a value
/// rather than a rewrite.
///
/// The label ladder (`primary` down to `faintest`) replaces the scattered
/// `Color.white` and `Color(white: 1, opacity: …)` literals. The opacities are
/// not mirrored between themes: black at 0.55 on white reads considerably
/// heavier than white at 0.55 on near-black did, so the light ladder is pulled
/// back at every rung. A mechanical inversion looks muddy and over-inked.
struct Palette: Sendable {
    // Text and iconography, strongest to faintest.
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let faint: Color
    let faintest: Color

    /// Fills and hairlines drawn over the backdrop.
    let surface: Color
    let surfaceHover: Color
    let hairline: Color

    /// Behind the settings pane and the connect/sign-in overlay.
    let chrome: Color
    let overlayScrim: Color
    let toastBackground: Color

    let positive: Color
    let negative: Color
    /// A holding Kite has not priced yet -- deliberately muted, not coloured.
    let unpriced: Color

    /// How strongly to wash the backdrop art toward the theme. The eight
    /// backdrops are dark-tuned raster images; in light mode they are tinted
    /// rather than replaced, because commissioning a second set of eight to
    /// serve a theme toggle is not a trade worth making.
    let backdropTint: Color
    let backdropTintOpacity: Double
    /// Grain is a dark-mode texture. Over a light wash it reads as dirt.
    let grainOpacity: Double

    let appearance: NSAppearance.Name

    static let dark = Palette(
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
    static let light = Palette(
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

    static func of(_ theme: ResolvedTheme) -> Palette {
        theme == .dark ? .dark : .light
    }
}

private struct PaletteKey: EnvironmentKey {
    /// Dark is the app's original and only look, so it is the safe default for
    /// any view rendered outside an injected hierarchy (previews included).
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Resolves the user's `ThemeMode` against the live system appearance and puts
/// the result in the environment.
///
/// `.system` is why this is a view rather than a stored value: it has to be
/// recomputed when the OS flips to dark at sunset, and reading
/// `@Environment(\.colorScheme)` here is what makes that automatic.
struct ThemedContainer<Content: View>: View {
    let mode: ThemeMode
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    private var resolved: ResolvedTheme {
        ResolvedTheme.resolve(mode: mode, systemIsDark: colorScheme == .dark)
    }

    var body: some View {
        content
            .environment(\.palette, .of(resolved))
            // Keeps AppKit-drawn pieces inside this hierarchy -- text fields,
            // focus rings, scrollers -- in step with the palette.
            .preferredColorScheme(resolved == .dark ? .dark : .light)
    }
}
