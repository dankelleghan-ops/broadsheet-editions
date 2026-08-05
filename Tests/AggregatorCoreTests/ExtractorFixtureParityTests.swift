import XCTest
@testable import AggregatorCore

/// Runs the VENDORED extractor against the app suite's own fixtures (BroadsheetTests/Fixtures)
/// -- the same inputs the app's ContentExtractorTests pin -- as a cross-package parity check.
final class ExtractorFixtureParityTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AggregatorCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // aggregator
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("BroadsheetTests/Fixtures")
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixturesDir.appendingPathComponent(name), encoding: .utf8)
    }

    private func item(url: String) -> FeedItem {
        FeedItem(guid: url, url: URL(string: url)!, title: "Fixture", summary: nil,
                 publishedAt: nil, feedCategories: [], contentHTML: nil, imageURLs: [])
    }

    func testFeedContentFixtureExtractsLikeTheApp() throws {
        let html = try fixture("feed-content.html")
        let extracted = try ContentExtractor().extract(fromFeedHTML: html,
                                                       item: item(url: "https://example.com/story"))
        let paragraphs = extracted.bodyBlocks.filter { $0.kind == .paragraph }
        XCTAssertEqual(paragraphs.count, 3)
        // Entity decoding (curly quotes) survived the vendored path too.
        XCTAssertTrue(paragraphs[0].text?.contains("Chicago\u{2019}s lakefront trail reopened") == true)
        let images = extracted.bodyBlocks.filter { $0.kind == .image }
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].credit, "Jane Alvarez / Sun Chronicle")
        // Hero + dedup: the same photo referenced twice collapses to one allImageURLs entry.
        XCTAssertEqual(extracted.allImageURLs.count, 1)
        XCTAssertEqual(extracted.heroImageURL?.absoluteString,
                       "https://cdn.example.com/photos/lakefront-1600.jpg")
    }

    func testSlatePageFixtureExtractsThroughVendoredCatalogSelector() throws {
        let html = try fixture("page-slate.html")
        guard let slateConfig = SourceCatalog.all.first(where: { $0.id == "slate" }) else {
            return XCTFail("slate missing from vendored SourceCatalog")
        }
        let url = URL(string: "https://slate.com/news-and-politics/fixture.html")!
        let extracted = try ContentExtractor().extract(fromPageHTML: html, articleURL: url,
                                                       item: item(url: url.absoluteString),
                                                       config: slateConfig)
        // The fixture body is deliberately thin (the app's own test pins selector behavior,
        // not gate passage) -- assert the vendored catalog selector found the real story
        // container's paragraphs.
        XCTAssertGreaterThanOrEqual(extracted.bodyBlocks.filter { $0.kind == .paragraph }.count, 3)
    }

    func testAtomFixtureParsesThroughVendoredFeedParser() throws {
        let xml = try Data(contentsOf: fixturesDir.appendingPathComponent("atom-fulltext.xml"))
        let endpoint = FeedEndpoint(url: URL(string: "https://example.org/atom")!, defaultCategory: .chicago)
        let items = try FeedParser().parse(data: xml, endpoint: endpoint)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].guid, "urn:example:fare-freeze-2026")
        XCTAssertEqual(items[0].url.absoluteString, "https://example.org/news/fare-freeze")
        XCTAssertNotNil(items[0].contentHTML)
        XCTAssertEqual(items[0].feedCategories, ["Transit", "Chicago"])
    }
}
