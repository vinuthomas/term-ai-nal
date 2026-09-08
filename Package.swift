// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TermAInal",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "TermAInal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/TermAInal",
            // Swift 5 semantics: the tree has not been audited for Swift 6
            // strict concurrency. PaneController and AppDelegate are
            // main-actor by convention rather than declaration — see
            // docs/MIGRATION.md, Phase 4.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
