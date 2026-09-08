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
            // Migration scaffold still uses Swift 5 semantics; tightening to strict
            // concurrency is tracked in MIGRATION.md.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
