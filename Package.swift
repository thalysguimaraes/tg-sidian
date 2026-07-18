// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TGSidianKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "InstrumentationKit", targets: ["InstrumentationKit"]),
        .library(name: "SecurityKit", targets: ["SecurityKit"]),
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
        .library(name: "VaultKit", targets: ["VaultKit"]),
        .library(name: "IndexKit", targets: ["IndexKit"]),
        .library(name: "GraphKit", targets: ["GraphKit"]),
        .library(name: "ExtensionSDK", targets: ["ExtensionSDK"]),
        .library(name: "FeatureUI", targets: ["FeatureUI"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "tg-sidian", targets: ["TGSidianApp"]),
        .executable(name: "editor-engine-harness", targets: ["EditorEngineHarness"])
    ],
    dependencies: [
        // Reviewed 2026-07-16: v7.11.1 (b83108d10f42680d78f23fe4d4d80fc88dab3212).
        // Exact pin keeps the disposable index format and migration behavior reproducible.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(
            name: "AppCore"
        ),
        .target(
            name: "InstrumentationKit",
            dependencies: ["AppCore"]
        ),
        .target(
            name: "SecurityKit",
            dependencies: ["AppCore"]
        ),
        .target(
            name: "MarkdownKit",
            dependencies: ["AppCore"]
        ),
        .target(
            name: "VaultKit",
            dependencies: ["AppCore", "MarkdownKit"]
        ),
        .target(
            name: "IndexKit",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "GraphKit",
            dependencies: ["AppCore", "IndexKit"]
        ),
        .target(
            name: "ExtensionSDK",
            dependencies: ["AppCore"]
        ),
        .target(
            name: "FeatureUI",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit", "IndexKit",
                "GraphKit", "SecurityKit", "InstrumentationKit", "ExtensionSDK"
            ]
        ),
        .executableTarget(
            name: "TGSidianApp",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit", "IndexKit",
                "GraphKit", "SecurityKit", "InstrumentationKit", "FeatureUI"
            ],
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "EditorEngineHarness",
            dependencies: ["AppCore", "FeatureUI", "VaultKit"]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["AppCore", "MarkdownKit", "VaultKit", "IndexKit", "GraphKit"]
        ),
        .testTarget(
            name: "TGSidianKitTests",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit", "IndexKit", "GraphKit",
                "SecurityKit", "FeatureUI", "TestSupport", "ExtensionSDK",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [.copy("Fixtures")]
        )
    ],
    // Swift 6 language mode enables complete strict-concurrency checking for every target.
    swiftLanguageModes: [.v6]
)
