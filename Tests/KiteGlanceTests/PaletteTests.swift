import XCTest
import SwiftUI
import AppKit
@testable import KiteGlanceCore

/// Mirrors the Windows `ThemeTests` parity check: a key defined in one
/// palette but not the other would mean a control falls back to a hard-
/// coded colour in one theme but not the other. Catching the asymmetry
/// here is what stops the light theme from going muddy in places the
/// dark theme renders cleanly.
final class PaletteTests: XCTestCase {

    /// Reflects over the stored properties of `Palette` so this test stays
    /// accurate as fields are added. The set of property names is the
    /// contract: any future palette field has to be present in both
    /// `Palette.dark` and `Palette.light`.
    func testDarkAndLightDefineTheSameKeys() {
        let darkKeys = Set(Mirror(reflecting: Palette.dark).children.compactMap { $0.label })
        let lightKeys = Set(Mirror(reflecting: Palette.light).children.compactMap { $0.label })

        XCTAssertFalse(darkKeys.isEmpty, "Mirror produced no keys -- has Palette been refactored into a non-mirrored type?")
        XCTAssertEqual(darkKeys, lightKeys, "Palette.dark and Palette.light must define the same fields. Missing in light: \(darkKeys.subtracting(lightKeys)); missing in dark: \(lightKeys.subtracting(darkKeys))")
    }

    /// A `clear` chrome on the dark theme would defeat the settings
    /// material entirely. Sanity-check that the named fields are not
    /// accidentally transparent.
    func testChromeAndOverlayScrimAreNotClear() {
        XCTAssertNotEqual(Palette.dark.chrome, Color.clear)
        XCTAssertNotEqual(Palette.light.chrome, Color.clear)
        XCTAssertNotEqual(Palette.dark.overlayScrim, Color.clear)
        XCTAssertNotEqual(Palette.light.overlayScrim, Color.clear)
    }

    /// The backdrop tint opacity is 0 in dark mode (the raster art is
    /// already dark) and non-zero in light. A flip would mean the
    /// dark theme suddenly tints toward white, or the light theme
    /// never lightens.
    func testBackdropTintOpacityDiffersBetweenThemes() {
        XCTAssertEqual(Palette.dark.backdropTintOpacity, 0)
        XCTAssertGreaterThan(Palette.light.backdropTintOpacity, 0)
    }

    /// The positive and negative accents must be different colours in
    /// both themes -- a regression that flipped them to the same value
    /// would render every P&L the same colour. Compares RGBA
    /// representations so the assertion is about paint output, not
    /// `NSObject` identity.
    func testPositiveAndNegativeDiffer() {
        XCTAssertNotEqual(rgba(Palette.dark.positive), rgba(Palette.dark.negative))
        XCTAssertNotEqual(rgba(Palette.light.positive), rgba(Palette.light.negative))
    }

    /// The `appearance` is what the NSWindow chrome reads; a mismatched
    /// appearance would put dark text on a dark titlebar in light mode.
    func testAppearanceMatchesTheme() {
        XCTAssertEqual(Palette.dark.appearance, .darkAqua)
        XCTAssertEqual(Palette.light.appearance, .aqua)
    }

    /// Resolves a SwiftUI `Color` to its RGBA representation. Avoids
    /// `NSColor` equality, which is identity-based on `NSObject`.
    private func rgba(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }
}
