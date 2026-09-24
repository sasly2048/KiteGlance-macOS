import SwiftUI
import AppKit
import KiteGlanceCore

/// The palette values themselves live in `KiteGlanceCore` so the parity
/// test in `Tests/KiteGlanceTests/PaletteTests.swift` can reach both
/// `Palette.dark` and `Palette.light` -- `XCTest` cannot import an
/// executable target. This file is just the SwiftUI glue that puts the
/// active palette into the environment.

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
