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
            name: "AppCore",
            path: "Packages/TGSidianKit/Sources/AppCore"
        ),
        .target(
            name: "InstrumentationKit",
            dependencies: ["AppCore"],
            path: "Packages/TGSidianKit/Sources/InstrumentationKit"
        ),
        .target(
            name: "SecurityKit",
            dependencies: ["AppCore"],
            path: "Packages/TGSidianKit/Sources/SecurityKit"
        ),
        .target(
            name: "MarkdownKit",
            dependencies: ["AppCore"],
            path: "Packages/TGSidianKit/Sources/MarkdownKit"
        ),
        .target(
            name: "VaultKit",
            dependencies: ["AppCore", "MarkdownKit"],
            path: "Packages/TGSidianKit/Sources/VaultKit"
        ),
        .target(
            name: "IndexKit",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Packages/TGSidianKit/Sources/IndexKit"
        ),
        .target(
            name: "GraphKit",
            dependencies: ["AppCore", "IndexKit"],
            path: "Packages/TGSidianKit/Sources/GraphKit"
        ),
        .target(
            name: "ExtensionSDK",
            dependencies: ["AppCore"],
            path: "Packages/TGSidianKit/Sources/ExtensionSDK"
        ),
        .target(
            name: "FeatureUI",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit", "IndexKit",
                "GraphKit", "SecurityKit", "InstrumentationKit", "ExtensionSDK"
            ],
            path: "Packages/TGSidianKit/Sources/FeatureUI"
        ),
        .executableTarget(
            name: "TGSidianApp",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit", "IndexKit",
                "GraphKit", "SecurityKit", "InstrumentationKit", "FeatureUI"
            ],
            path: "App",
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "EditorEngineHarness",
            dependencies: ["AppCore", "FeatureUI", "VaultKit"],
            path: "Tools/EditorEngineHarness"
        ),
        .target(
            name: "TestSupport",
            dependencies: ["AppCore", "MarkdownKit", "VaultKit", "IndexKit", "GraphKit"],
            path: "Packages/TGSidianKit/Sources/TestSupport"
        ),
        .testTarget(
            name: "TGSidianKitTests",
            dependencies: [
                "AppCore", "MarkdownKit", "VaultKit", "IndexKit", "GraphKit",
                "SecurityKit", "FeatureUI", "TestSupport", "ExtensionSDK",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/TGSidianKitTests",
            resources: [.copy("Fixtures")]
        )
    ],
    // Swift 6 language mode enables complete strict-concurrency checking for every target.
    swiftLanguageModes: [.v6]
)
