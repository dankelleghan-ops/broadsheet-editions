import XCTest
@testable import AggregatorCore

/// The vendored copies under Sources/AggregatorCore/Vendored/ must stay byte-identical to
/// their originals under Broadsheet/ -- drift is detectable, never silent (the other half of
/// sync-shared-sources.sh's manifest). Runs on every `swift test`.
final class VendoredSourceDriftTests: XCTestCase {

    /// Keep in lockstep with sync-shared-sources.sh's FILES array.
    static let sharedSourcePaths = [
        "Broadsheet/Sources/SourceCatalog.swift",
        "Broadsheet/Pipeline/FeedParser.swift",
        "Broadsheet/Pipeline/ContentExtractor.swift",
        "Broadsheet/Pipeline/ArticleGate.swift",
        "Broadsheet/Pipeline/LanguageFilter.swift",
        "Broadsheet/Models/CoreTypes.swift",
        "Broadsheet/Models/ArticleCategory.swift",
        "Broadsheet/Support/AttributionText.swift"
    ]

    private var repoRoot: URL {
        // .../aggregator/Tests/AggregatorCoreTests/VendoredSourceDriftTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AggregatorCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // aggregator
            .deletingLastPathComponent()  // repo root
    }

    func testVendoredCopiesMatchOriginalsByteForByte() throws {
        let vendoredDir = repoRoot.appendingPathComponent("aggregator/Sources/AggregatorCore/Vendored")
        for relativePath in Self.sharedSourcePaths {
            let original = repoRoot.appendingPathComponent(relativePath)
            let vendored = vendoredDir.appendingPathComponent(
                URL(fileURLWithPath: relativePath).lastPathComponent)
            let originalData = try Data(contentsOf: original)
            let vendoredData = try Data(contentsOf: vendored)
            XCTAssertEqual(originalData, vendoredData,
                           "DRIFT: \(relativePath) differs from its vendored copy -- run aggregator/sync-shared-sources.sh")
        }
    }

    func testManifestIsCurrent() throws {
        let manifestURL = repoRoot.appendingPathComponent(
            "aggregator/Sources/AggregatorCore/Vendored/MANIFEST.sha256")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        for relativePath in Self.sharedSourcePaths {
            let original = repoRoot.appendingPathComponent(relativePath)
            let sha = SHA256.hexDigest(try Data(contentsOf: original))
            XCTAssertTrue(manifest.contains("\(sha)  \(relativePath)"),
                          "MANIFEST.sha256 stale for \(relativePath) -- run aggregator/sync-shared-sources.sh")
        }
    }
}
