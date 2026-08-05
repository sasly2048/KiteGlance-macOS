// swift-tools-version: 6.0
import PackageDescription

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
            path: "Sources/KiteGlanceCore"
        ),
        .executableTarget(
            name: "KiteGlance",
            dependencies: ["KiteGlanceCore"],
            path: "Sources/KiteGlance",
            exclude: ["Info.plist"],
            resources: [
                // `Assets/Icons` was listed here but does not exist, which is a
                // hard error in SwiftPM. Only declare directories that are real.
                .process("Assets/Backdrops")
            ],
            swiftSettings: [
                .define("RELEASE", .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security")
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
