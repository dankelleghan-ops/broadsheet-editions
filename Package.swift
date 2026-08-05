// swift-tools-version:5.9
// BroadsheetAggregator -- the server-side edition compiler for the Broadsheet iOS app.
//
// LINUX-COMPATIBLE is a hard requirement (GitHub Actions runners are Ubuntu): Foundation +
// SwiftSoup only. No UIKit / ImageIO / AppKit / NaturalLanguage anywhere in this package --
// image resizing shells out to ImageMagick (Linux) or sips (macOS), and language detection's
// ML fallback is compiled out on Linux (see Vendored/LanguageFilter.swift).
//
// SwiftSoup is pinned to the same version the app resolves (2.13.7 at the time of writing --
// see Broadsheet.xcodeproj/.../Package.resolved) so vendored ContentExtractor behavior matches
// the app's exactly.
import PackageDescription

let package = Package(
    name: "BroadsheetAggregator",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.13.7")
    ],
    targets: [
        .target(
            name: "AggregatorCore",
            dependencies: ["SwiftSoup"]
        ),
        .executableTarget(
            name: "compile-edition",
            dependencies: ["AggregatorCore"]
        ),
        .testTarget(
            name: "AggregatorCoreTests",
            dependencies: ["AggregatorCore"]
        )
    ]
)
