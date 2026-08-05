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
        .executableTarget(
            name: "KiteGlance",
            dependencies: [],
            path: "Sources/KiteGlance",
            resources: [
                .process("Assets/Backdrops"),
                .process("Assets/Icons"),
                .copy("Info.plist")
            ],
            swiftSettings: [
                .unsafeFlags(["-O", "-whole-module-optimization"], .when(configuration: .release)),
                .define("RELEASE", .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit")
            ]
        ),
        .executableTarget(
            name: "GenerateAssets",
            dependencies: [],
            path: "scripts",
            sources: ["generate-assets.swift"]
        )
    ]
)