// swift-tools-version: 6.0
import PackageDescription

// The floor is macOS 15 (Sequoia). Tested on the latest macOS the GitHub
// Actions macos-* runner family provides; the build matrix in
// .github/workflows/build.yml runs against every available runner.
//
// macOS 15 (Sequoia) is the minimum because:
//   * AppDelegate uses @MainActor isolation (Swift 5.10+ semantics)
//   * `MenuItem.submenu` is a property setter, not a constructor (macOS 14+)
//   * `KiteService.request(...)` uses the async URLSession data(for:) overload
//
// The new Liquid Glass `NSVisualEffectView.Material.glass` is macOS 26+.
// `VisualEffectMaterial.swift` wraps it in `if #available(macOS 26.0, *)`
// and falls back to `.hudWindow` on 15-25, so the floor stays at 15. The
// widget looks the same on a 2023 MacBook as on a 2026 Mac Studio -- the
// OS draws the vibrancy layer differently, but the painted SwiftUI pixels
// are identical.
let package = Package(
    name: "KiteGlance",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "KiteGlance", targets: ["KiteGlance"]),
        .executable(name: "generate-assets", targets: ["GenerateAssets"])
    ],
    dependencies: [],
    targets: [
        // The app's logic, split out so it can be linked into the test target.
        // XCTest cannot import an executable target, so everything testable --
        // P&L math, AMFI parsing, backdrop selection, name formatting -- lives
        // here and the executable below is just the entry point.
        .target(
            name: "KiteGlanceCore",
            dependencies: [],
            path: "Sources/KiteGlanceCore",
            linkerSettings: [
                // `Palette` lives in Core so the parity test in
                // `Tests/KiteGlanceTests/PaletteTests.swift` can reach both
                // `Palette.dark` and `Palette.light`. SwiftUI and AppKit
                // provide `Color` and `NSAppearance.Name`.
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "KiteGlance",
            dependencies: ["KiteGlanceCore"],
            path: "Sources/KiteGlance",
            exclude: ["Info.plist", "Assets/Backdrops/README.md"],
            resources: [
                // `Assets/Icons` was also listed here but does not exist, which
                // is a hard error in SwiftPM. Only declare real directories.
                //
                // The PNGs are generated (`swift run generate-assets`) and
                // gitignored, so this directory is empty in a fresh clone --
                // `.copy` tolerates that, and the app falls back to gradients.
                .copy("Assets/Backdrops")
            ],
            swiftSettings: [
                // RELEASE is a marker the production code can read to swap in
                // stricter assertions; the debug build skips it.
                .define("RELEASE", .when(configuration: .release)),
                // Swift 6 strict-concurrency surfaced real issues here on the
                // first audit pass: callbacks crossing actor boundaries (the
                // LoginServer's `Task { await self.handleChunk(...) }` block,
                // the AppDelegate's NSStatusItem handlers) and @MainActor
                // Views using non-isolated targets. The settings are scoped to
                // this target only, so the pure-math KiteGlanceCore target can
                // stay Swift 5-mode for unit-test speed.
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security"),
                // `LoginLaunchService` uses `SMAppService` from
                // `ServiceManagement` for the "Open at Login" toggle.
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "GenerateAssets",
            dependencies: [],
            path: "scripts",
            sources: ["generate-assets.swift"]
        ),
        .testTarget(
            name: "KiteGlanceTests",
            dependencies: ["KiteGlanceCore"],
            path: "Tests/KiteGlanceTests"
        )
    ]
)
