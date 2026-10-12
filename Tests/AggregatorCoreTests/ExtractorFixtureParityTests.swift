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

    /// ABC7's mobile "Top Stories" promo (`section.MobileContentPromo[data-testid=prism-collection]`)
    /// sits BETWEEN the paragraphs of the article body in some page responses; 20 of 34 ABC7
    /// articles in the 2026-10-12 edition had its label, three teaser headlines and three teaser
    /// photos in the middle of their text. Mirrors the app suite's ContentExtractorTests: the
    /// vendored extractor, through the vendored catalog entry, must strip it.
    func testAbc7TopStoriesModuleIsStrippedThroughVendoredCatalog_realCapture() throws {
        let html = try fixture("page-abc7-top-stories-module.html")
        guard let abc7 = SourceCatalog.all.first(where: { $0.id == "abc7" }) else {
            return XCTFail("abc7 missing from vendored SourceCatalog")
        }
        let url = URL(string: "https://abc7.com/post/us-stocks-hover/19932185/")!
        let extracted = try ContentExtractor().extract(fromPageHTML: html, articleURL: url,
                                                       item: item(url: url.absoluteString), config: abc7)
        XCTAssertEqual(extracted.bodyBlocks.filter { $0.kind == .heading }.count, 0)
        XCTAssertFalse(extracted.bodyBlocks.contains { ($0.text ?? "").contains("Top Stories") })
        XCTAssertFalse(extracted.bodyBlocks.contains { ($0.imageURLString ?? "").contains("kabc-am-forecast") })
        XCTAssertEqual(extracted.bodyBlocks.filter { $0.kind == .paragraph }.count, 11)
        XCTAssertEqual(extracted.bodyBlocks.filter { $0.kind == .image }.compactMap { $0.imageURLString },
                       ["https://cdn.abcotvs.com/dip/images/19932187_ap-stock-img.jpg"])
    }

    func testAbc7PoisoningStoryWithModuleKeepsItsEightParagraphsInOrder() throws {
        let abc7 = try XCTUnwrap(SourceCatalog.all.first(where: { $0.id == "abc7" }))
        let url = URL(string: "https://abc7chicago.com/story/video-california-man/19932364/")!
        let withModule = try ContentExtractor().extract(
            fromPageHTML: try fixture("page-abc7-chicago-poisoning-with-module.html"),
            articleURL: url, item: item(url: url.absoluteString), config: abc7)
        let asFetched = try ContentExtractor().extract(
            fromPageHTML: try fixture("page-abc7-chicago-poisoning.html"),
            articleURL: url, item: item(url: url.absoluteString), config: abc7)
        XCTAssertEqual(asFetched.bodyBlocks.count, 8)
        XCTAssertTrue(asFetched.bodyBlocks.allSatisfy { $0.kind == .paragraph })
        // With the widget present the result must be identical to the page without it.
        XCTAssertEqual(withModule.bodyBlocks.map { $0.text }, asFetched.bodyBlocks.map { $0.text })
        XCTAssertTrue(withModule.bodyBlocks.allSatisfy { $0.kind == .paragraph })
    }

    /// The mid-body teaser-run guard (label + 3 or more uncaptioned image/heading pairs with no
    /// paragraph between) lives in the vendored ContentExtractor too; the app suite pins the rule
    /// in depth, this pins that the compiler's copy has it.
    func testVendoredTeaserRunGuardRemovesCarouselAndKeepsCaptionedSections() {
        func block(_ kind: BodyBlock.Kind, _ text: String? = nil, image: String? = nil, caption: String? = nil) -> BodyBlock {
            BodyBlock(kind: kind, text: text, imageURLString: image, caption: caption, credit: nil)
        }
        let carousel = [block(.paragraph, "a"),
                        block(.heading, "Top Stories"),
                        block(.image, image: "https://x/1.jpg"), block(.heading, "One"),
                        block(.image, image: "https://x/2.jpg"), block(.heading, "Two"),
                        block(.image, image: "https://x/3.jpg"), block(.heading, "Three"),
                        block(.paragraph, "b")]
        XCTAssertEqual(ContentExtractor.dropTeaserRuns(carousel).map { $0.text }, ["a", "b"])

        let guide = [block(.paragraph, "a"),
                     block(.image, image: "https://x/1.jpg", caption: "Chapel"), block(.heading, "Hyde Park"),
                     block(.image, image: "https://x/2.jpg", caption: "Theater"), block(.heading, "South Shore"),
                     block(.image, image: "https://x/3.jpg", caption: "Beach"), block(.heading, "Rainbow Beach")]
        XCTAssertEqual(ContentExtractor.dropTeaserRuns(guide).count, guide.count)
    }

    // MARK: - 2026-10-12 page furniture (BBC, ABC7, Vox, NY Post / Decider)
    //
    // The fixtures are real captures fetched with the compiler's own User-Agent. The compiler runs
    // the VENDORED extractor and catalog, so these pin that its copy of the per-source rules cleans
    // the same pages the app suite's ContentExtractorTests pin.

    private func extractViaVendoredCatalog(_ fixtureName: String, url: String, sourceID: String) throws -> ExtractedArticle {
        guard let config = SourceCatalog.all.first(where: { $0.id == sourceID }) else {
            XCTFail("\(sourceID) missing from vendored SourceCatalog")
            throw XCTSkip("missing source")
        }
        let articleURL = URL(string: url)!
        return try ContentExtractor().extract(fromPageHTML: try fixture(fixtureName), articleURL: articleURL,
                                              item: item(url: url), config: config)
    }

    func testBbcMoreOnThisStoryRelatedTopicsAndAfricaPodcastsAreStrippedThroughVendoredCatalog() throws {
        let more = try extractViaVendoredCatalog(
            "page-bbc-more-on-this-story.html",
            url: "https://www.bbc.co.uk/news/articles/c6m2dnngvw8xo?at_medium=RSS&at_campaign=rss", sourceID: "bbc")
        XCTAssertEqual(more.bodyBlocks.count, 18)
        XCTAssertTrue(more.bodyBlocks.allSatisfy { $0.kind == .paragraph })
        XCTAssertEqual(more.bodyBlocks.last?.text, "Most nodules do not cause other symptoms.")
        XCTAssertFalse(more.bodyBlocks.contains { $0.text == "More on this story" || $0.text == "Related topics" })

        let podcasts = try extractViaVendoredCatalog(
            "page-bbc-africa-podcasts.html",
            url: "https://www.bbc.co.uk/news/articles/c8wy9d940pyko?at_medium=RSS&at_campaign=rss", sourceID: "bbc")
        XCTAssertEqual(podcasts.bodyBlocks.count, 22)
        for junk in ["Related topics", "BBC Africa podcasts", "Focus on Africa", "This Is Africa"] {
            XCTAssertFalse(podcasts.bodyBlocks.contains { $0.text == junk }, "'\(junk)' leaked into the body")
        }
    }

    func testAbc7LiveStreamPromoHeadingIsStrippedThroughVendoredCatalog() throws {
        let extracted = try extractViaVendoredCatalog(
            "page-abc7-live-stream-heading.html",
            url: "https://abc7chicago.com/post/uchicago-news-university-chicago-fraternity-says-cooperating-police-sex-assault-report/19932343/",
            sourceID: "abc7")
        XCTAssertEqual(extracted.bodyBlocks.count, 20)
        XCTAssertTrue(extracted.bodyBlocks.allSatisfy { $0.kind == .paragraph })
        XCTAssertFalse(extracted.bodyBlocks.contains { ($0.text ?? "").contains("streaming 24/7") })
    }

    func testVoxRelatedModulesAreStrippedThroughVendoredCatalog() throws {
        let extracted = try extractViaVendoredCatalog(
            "page-vox-related-module.html",
            url: "https://www.vox.com/explain-it-to-me/505163/pet-insurance-veterinary-care-expensive-private-equity",
            sourceID: "vox")
        XCTAssertEqual(extracted.bodyBlocks.filter { $0.kind == .heading }.count, 0)
        XCTAssertEqual(extracted.bodyBlocks.filter { $0.kind == .paragraph }.count, 30)
        XCTAssertEqual(extracted.bodyBlocks.count, 33)
    }

    func testNyPostFeedDeciderWidgetsAndTrustHeadingAreStrippedThroughVendoredCatalog() throws {
        let decider = try extractViaVendoredCatalog(
            "page-decider-where-to-stream.html",
            url: "https://decider.com/2026/10/12/marshals-season-2-episode-2-recap-tate-me-later/", sourceID: "nypost")
        XCTAssertEqual(decider.bodyBlocks.count, 12)
        XCTAssertEqual(decider.bodyBlocks.filter { $0.kind == .paragraph }.count, 9)
        for junk in ["Share this:", "Where to Stream:", "More On:"] {
            XCTAssertFalse(decider.bodyBlocks.contains { $0.text == junk }, "'\(junk)' leaked into the body")
        }
        XCTAssertFalse(decider.bodyBlocks.contains { ($0.imageURLString ?? "").contains("reelgood") })
        XCTAssertEqual(decider.bodyBlocks.first?.text?.hasPrefix("A Dutton man would rather run far from his father"), true)

        let trust = try extractViaVendoredCatalog(
            "page-nypost-why-trust-heading.html",
            url: "https://nypost.com/2026/10/10/sports/how-to-watch-guardians-vs-white-sox-alds-game-5-for-free-time-livestream/",
            sourceID: "nypost")
        XCTAssertEqual(trust.bodyBlocks.count, 17)
        XCTAssertFalse(trust.bodyBlocks.contains { ($0.text ?? "").hasPrefix("Why you should trust") })
        XCTAssertTrue(trust.bodyBlocks.contains { ($0.text ?? "").hasPrefix("This article was written by Matt Levy") })

        // Control: an ordinary article comes out whole.
        let ordinary = try extractViaVendoredCatalog(
            "page-nypost-ordinary-news.html",
            url: "https://nypost.com/2026/10/10/sports/guardians-stun-white-sox-with-21-strikeouts-to-win-alds-after-2-0-deficit/",
            sourceID: "nypost")
        XCTAssertEqual(ordinary.bodyBlocks.count, 23)
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
