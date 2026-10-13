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

    // MARK: - hero shown once (2026-10-12)
    //
    // The same real captures the app suite's HeroShownOnceTests pins, run through the VENDORED extractor and
    // catalog -- the compiler's copy must mark exactly the same blocks and choose exactly the same hero.

    func testHeroShownOnce_realPagesThroughVendoredCatalog() throws {
        // Every expectation is written out by hand: the hero, the EXACT image blocks that must be marked, and the
        // EXACT ones that must stay plain. (A check that asked `samePhoto` whether the unmarked blocks were the hero
        // would pass for any matcher that is wrong the same way in both places.)
        struct Case {
            let fixture: String, url: String, source: String
            let hero: String
            let marked: [String]    // image blocks flagged repeatsHero, in order
            let unmarked: [String]  // image blocks left alone, in order
        }
        let bbc = "https://ichef.bbci.co.uk/ace/standard/"
        let npr = "https://npr.brightspotcdn.com/dims3/default/strip/false/crop/"
        let nprS3 = "?url=http%3A%2F%2Fnpr-brightspot.s3.amazonaws.com%2F"
        let vegan2400 = "https://platform.vox.com/wp-content/uploads/sites/2/2026/10/Vegan-Jr.jpg?quality=90&strip=all&crop=0%2C0.015446400988566%2C100%2C99.969107198023&w=2400"
        let cases = [
            Case(fixture: "page-bbc-lead-photo-after-paragraphs.html", url: "https://www.bbc.co.uk/news/articles/cvp8glg97393o", source: "bbc",
                 hero: bbc + "1200/cpsprodpb/dc45/live/01c4d970-c64f-11f1-b47f-e3f9cf703bc3.png",
                 marked: [bbc + "1680/cpsprodpb/dc45/live/01c4d970-c64f-11f1-b47f-e3f9cf703bc3.png"],
                 unmarked: [bbc + "1024/cpsprodpb/bdbc/live/255fca30-c63f-11f1-abff-0d918239b2e3.jpg"]),
            Case(fixture: "page-bbc-no-lead-photo.html", url: "https://www.bbc.co.uk/news/articles/cr93znyk44e1o", source: "bbc",
                 hero: bbc + "1200/cpsprodpb/2165/live/f588e620-c602-11f1-9a39-31b474234113.jpg",
                 marked: [],
                 unmarked: [bbc + "1600/cpsprodpb/53a4/live/4134abe0-c581-11f1-9a39-31b474234113.png",
                            bbc + "800/cpsprodpb/debe/live/a124f880-c57b-11f1-a64c-550be9e3c66b.jpg"]),
            Case(fixture: "page-bbc-sport-branded.html", url: "https://www.bbc.co.uk/sport/football/articles/cmd7qn1g0xrxo", source: "bbc",
                 hero: bbc + "1200/cpsprodpb/779a/live/b7058b10-c616-11f1-bc2e-018d645d8d21.jpg",
                 marked: [bbc + "3840/cpsprodpb/779a/live/b7058b10-c616-11f1-bc2e-018d645d8d21.jpg"],
                 unmarked: []),
            // The real separate-upload case: og asset 5ebc/216ece00, lead figure 4d0e/6040a720 (another uuid).
            Case(fixture: "page-bbc-og-separate-upload.html", url: "https://www.bbc.co.uk/news/articles/cmpwg28vrexzo", source: "bbc",
                 hero: bbc + "1200/cpsprodpb/4d0e/live/6040a720-c64c-11f1-bc2e-018d645d8d21.jpg",
                 marked: [bbc + "976/cpsprodpb/4d0e/live/6040a720-c64c-11f1-bc2e-018d645d8d21.jpg"],
                 unmarked: [bbc + "1024/cpsprodpb/b6f2/live/f13c8400-c260-11f1-a202-b3a903690ffe.jpg"]),
            Case(fixture: "page-bbc-africa-podcasts.html", url: "https://www.bbc.co.uk/news/articles/c8wy9d940pyko", source: "bbc",
                 hero: bbc + "1200/cpsprodpb/42c8/live/68991b20-c64a-11f1-b47f-e3f9cf703bc3.jpg",
                 marked: [bbc + "3840/cpsprodpb/42c8/live/68991b20-c64a-11f1-b47f-e3f9cf703bc3.jpg"],
                 unmarked: [bbc + "976/cpsprodpb/a743/live/681bd460-6ee0-11f1-8e1d-bbbb1017d210.png"]),
            Case(fixture: "page-bbc-more-on-this-story.html", url: "https://www.bbc.co.uk/news/articles/c6m2dnngvw8xo", source: "bbc",
                 hero: bbc + "1200/cpsprodpb/13bb/live/c2ac8480-c569-11f1-bd33-db1f7eaf2b30.jpg",
                 marked: [], unmarked: []),
            // Clean og:images: the hero is untouched, the body copy is marked (NPR/Vox: same path or url= original;
            // CBS: the LATER body photo, on another shard host).
            Case(fixture: "page-npr-nobel.html", url: "https://www.npr.org/2026/10/09/nx-s1-5996634/nobel-prize-in-economics", source: "npr",
                 hero: npr + "7794x4384+0+0/resize/1400/quality/85/format/jpeg/" + nprS3 + "26%2F78%2Fddfdc1d243f09e93115d2fbd57d2%2Fgettyimages-2299286819.jpg",
                 marked: [npr + "7794x5310+0+0/resize/1100/quality/50/format/jpeg/" + nprS3 + "26%2F78%2Fddfdc1d243f09e93115d2fbd57d2%2Fgettyimages-2299286819.jpg"],
                 unmarked: [npr + "3508x3508+0+0/resize/100/quality/85/format/jpeg/" + nprS3 + "5f%2F67%2F41db4eea4773be58f06b14e0c2f2%2Fap26284021705014.jpg",
                            npr + "4000x4000+906+0/resize/100/quality/85/format/jpeg/" + nprS3 + "f2%2Fa1%2F2bc298f340b38e8dadaa0dabb377%2Fgettyimages-2297110253.jpg"]),
            Case(fixture: "page-vox-vegan.html", url: "https://www.vox.com/future-perfect/505747/kid-moral-choices-vegan-parenting", source: "vox",
                 hero: "https://platform.vox.com/wp-content/uploads/sites/2/2026/10/Vegan-Jr.jpg?quality=90&strip=all&crop=0%2C10.745114974598%2C100%2C78.509770050803&w=1200",
                 marked: [vegan2400, vegan2400],
                 unmarked: ["https://platform.vox.com/wp-content/uploads/sites/2/2026/06/Shayla-Love-headshot.png?quality=90&strip=all&crop=0%2C16.4%2C100%2C67.2&w=96"]),
            Case(fixture: "page-cbs-isaias.html", url: "https://www.cbsnews.com/news/hurricane-isaias-destruction-southeast/", source: "cbs",
                 hero: "https://assets3.cbsnewsstatic.com/hub/i/r/2026/10/12/2d9229d1-84a4-40b0-8cc9-261630d7fec3/thumbnail/1200x630/5820a851f226c8f82370fc5750634060/gettyimages-2299587244.jpg",
                 marked: ["https://assets2.cbsnewsstatic.com/hub/i/r/2026/10/12/2d9229d1-84a4-40b0-8cc9-261630d7fec3/thumbnail/620x457/98bf6fc8989eb289c3cb909c38b299ec/gettyimages-2299587244.jpg#"],
                 unmarked: ["https://assets3.cbsnewsstatic.com/hub/i/r/2026/10/12/30b6887f-e08e-4e41-ba8f-3f525a070ae3/thumbnail/620x349/9498f66d23daca86138793f9806fa2e0/1791811756696.png#"])
        ]
        for c in cases {
            let article = try extractViaVendoredCatalog(c.fixture, url: c.url, sourceID: c.source)
            XCTAssertEqual(article.heroImageURL?.absoluteString, c.hero, c.fixture)
            let images = article.bodyBlocks.filter { $0.kind == .image }
            XCTAssertEqual(images.filter { $0.repeatsHero == true }.compactMap(\.imageURLString), c.marked, c.fixture)
            XCTAssertEqual(images.filter { $0.repeatsHero != true }.compactMap(\.imageURLString), c.unmarked, c.fixture)
            // Hero first, then every unmarked image, once each; marked copies are not downloaded (unless their URL IS
            // the hero's).
            let expectedDownloads = ([c.hero] + c.unmarked).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            XCTAssertEqual(article.allImageURLs.map(\.absoluteString), expectedDownloads, c.fixture)
        }
    }

    func testHeroShownOnce_feedTextHeroIsTheFirstImageBlock_evenMidArticle() throws {
        let para = "<p>Paragraph carries enough words to be a real paragraph of the story body.</p>"
        let html = para + para + "<figure><img src=\"https://cdn.example.com/p/mid-photo-1.jpg\"/><figcaption>Lead caption</figcaption></figure>"
            + para + "<img src=\"https://cdn.example.com/p/second-photo-2.jpg\"/>"
        let extracted = try ContentExtractor().extract(fromFeedHTML: html, item: item(url: "https://example.org/story"))
        XCTAssertEqual(extracted.heroImageURL?.absoluteString, "https://cdn.example.com/p/mid-photo-1.jpg")
        let images = extracted.bodyBlocks.filter { $0.kind == .image }
        XCTAssertEqual(images.map { $0.repeatsHero }, [true, nil])
        XCTAssertEqual(images.first?.caption, "Lead caption")
    }

    // MARK: hero shown once -- the matcher's two tightened rules, through the vendored copy
    //
    // Mirrors the app suite's HeroShownOnceTests. A path segment is an ASSET ID only when it is 24+ characters, has
    // a digit and is made of hex digits and dashes alone; hosts differing only by trailing digits on the FIRST label
    // are one CDN only when the host has three or more labels.

    private func same(_ a: String, _ b: String) -> Bool { ContentExtractor.samePhoto(URL(string: a)!, URL(string: b)!) }

    func testSamePhotoPositiveControls_oneAssetUnderDifferentRenditionsIsTheSamePhoto() {
        XCTAssertTrue(same("https://ichef.bbci.co.uk/ace/standard/976/cpsprodpb/779a/live/b7058b10-c616-11f1-bc2e-018d645d8d21.jpg",
                           "https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/779a/live/b7058b10-c616-11f1-bc2e-018d645d8d21.jpg"))
        let guardianAsset = "b731ec571946e4165d394b1c0795936a11412d78"
        XCTAssertTrue(same("https://i.guim.co.uk/img/media/\(guardianAsset)/671_195_4433_3548/master/4433.jpg?width=1200&quality=85&s=none",
                           "https://i.guim.co.uk/img/media/\(guardianAsset)/0_0_4000_3000/master/4000.jpg?width=700&dpr=2&s=none"))
        let cbs = "2d9229d1-84a4-40b0-8cc9-261630d7fec3"
        XCTAssertTrue(same("https://assets1.cbsnewsstatic.com/hub/i/r/2026/10/12/\(cbs)/thumbnail/1200x630/aaa/x.jpg",
                           "https://assets3.cbsnewsstatic.com/hub/i/r/2026/10/12/\(cbs)/thumbnail/620x349/bbb/x.jpg#"))
        let abc = "c3a9b2d4-7e61-4f08-9b5a-1d2e3f405a6b"
        XCTAssertTrue(same("https://i.abcnewsfe.com/a/\(abc)/gettyimages-2299586677_1760302441021_16x9.jpg?w=992",
                           "https://i.abcnewsfe.com/a/\(abc)/gettyimages-2299586677.jpg"))
        let original = "?url=http%3A%2F%2Fnpr-brightspot.s3.amazonaws.com%2F26%2F78%2Fddfdc1d243f09e93115d2fbd57d2%2Fgettyimages-2299286819.jpg"
        XCTAssertTrue(same("https://npr.brightspotcdn.com/dims3/default/strip/false/crop/7794x4384+0+0/resize/1400/quality/85/format/jpeg/\(original)",
                           "https://npr.brightspotcdn.com/dims3/default/strip/false/crop/7794x5310+0+0/resize/1100/quality/50/format/jpeg/\(original)"))
        XCTAssertTrue(same("https://i0.wp.com/site.example/uploads/2026/07/Photo.jpg?fit=1024%2C683",
                           "https://i2.wp.com/site.example/uploads/2026/07/Photo.jpg?resize=1536%2C1024"))
    }

    func testSamePhotoNegativeControls_aSharedCloudinaryTransformSegmentIsNotAnAssetId() {
        // Two DIFFERENT NBC News photographs sharing `t_focal-260x130,f_avif,q_auto:best` (34 characters, has digits).
        let base = "https://media-cldnry.s-nbcnews.com/image/upload/t_focal-260x130,f_avif,q_auto:best/rockcms/2026-10/"
        XCTAssertFalse(same(base + "251012-hurricane-isaias-damage-ac-1130p-8b1f3c.jpg",
                            base + "251012-white-house-briefing-ac-1245p-2d9e7a.jpg"))
        // Long but not hex, or hex without a digit: not an id. The same segment as a real id (digit, hex only): one.
        XCTAssertFalse(same("https://img.example.com/a/deadbeef-dead-beef-dead-beefdead/one.jpg",
                            "https://img.example.com/b/deadbeef-dead-beef-dead-beefdead/two.jpg"))
        XCTAssertFalse(same("https://img.example.com/a/0f1e2d3c4b5a69788796a5b4c3d2e1fg/one.jpg",
                            "https://img.example.com/b/0f1e2d3c4b5a69788796a5b4c3d2e1fg/two.jpg"))
        XCTAssertTrue(same("https://img.example.com/a/0f1e2d3c4b5a69788796a5b4c3d2e1f0/one.jpg",
                           "https://img.example.com/b/0f1e2d3c4b5a69788796a5b4c3d2e1f0/two.jpg"))
        // Different originals / different uuid folders / different hosts are different photographs.
        XCTAssertFalse(same("https://assets1.cbsnewsstatic.com/hub/i/r/2026/10/12/2d9229d1-84a4-40b0-8cc9-261630d7fec3/thumbnail/1200x630/aaa/x.jpg",
                            "https://assets2.cbsnewsstatic.com/hub/i/r/2026/10/12/30b6887f-e08e-4e41-ba8f-3f525a070ae3/thumbnail/620x349/bbb/y.png"))
    }

    func testSamePhotoNegativeControls_shardsNeedThreeLabelsAndOnlyTrailingDigitsOfTheFirstLabel() {
        let uuid = "2d9229d1-84a4-40b0-8cc9-261630d7fec3"
        XCTAssertFalse(same("https://abc1.com/x/\(uuid).jpg", "https://abc.com/x/\(uuid).jpg"), "two labels: a different site")
        XCTAssertFalse(same("https://abc.com/x/\(uuid).jpg", "https://abc1.com/x/\(uuid).jpg"))
        XCTAssertTrue(same("https://assets1.cbsnewsstatic.com/x/\(uuid).jpg", "https://assets3.cbsnewsstatic.com/x/\(uuid).jpg"))
        XCTAssertTrue(same("https://cdn2.example.com/p/\(uuid)/x.jpg", "https://cdn3.example.com/p/\(uuid)/x.jpg"))
        // A digit inside the label is part of its name (an implementation stripping every digit would call these one host).
        XCTAssertFalse(same("https://cdn2go.example.com/p/\(uuid)/x.jpg", "https://cdn3go.example.com/p/\(uuid)/x.jpg"))
        XCTAssertFalse(same("https://cdn.example2.com/p/\(uuid)/x.jpg", "https://cdn.example3.com/p/\(uuid)/x.jpg"))
        XCTAssertFalse(same("https://1.example.com/p/\(uuid)/x.jpg", "https://2.example.com/p/\(uuid)/x.jpg"))
    }

    func testHeroShownOnce_nbcShapedPage_anotherPhotoSharingTheTransformSegmentIsNotMarked() throws {
        let transform = "t_focal-260x130,f_avif,q_auto:best"
        let hero = "https://media-cldnry.s-nbcnews.com/image/upload/\(transform)/rockcms/2026-10/251012-hurricane-isaias-damage-ac-1130p-8b1f3c.jpg"
        let other = "https://media-cldnry.s-nbcnews.com/image/upload/\(transform)/rockcms/2026-10/251012-white-house-briefing-ac-1245p-2d9e7a.jpg"
        let para = "<p>Paragraph carries enough words to be a real paragraph of the story body.</p>"
        let html = """
        <html><head><meta property="og:image" content="\(hero)"/></head>
        <body><div id="story">\(para)\(para)
        <figure><img src="\(other)"/><figcaption>A different picture.</figcaption></figure>
        \(para)
        <figure><img src="\(hero)"/><figcaption>The lead picture, again.</figcaption></figure>
        \(para)</div></body></html>
        """
        let config = SourceConfig(id: "test", name: "Test", feeds: [], strategy: .pageExtract, weight: 1.0,
                                  bodySelector: "#story", excludeURLPatterns: [], maxPerDay: 40)
        let url = URL(string: "https://www.nbcnews.com/news/story")!
        let article = try ContentExtractor().extract(fromPageHTML: html, articleURL: url, item: item(url: url.absoluteString), config: config)
        XCTAssertEqual(article.heroImageURL?.absoluteString, hero)
        let images = article.bodyBlocks.filter { $0.kind == .image }
        XCTAssertEqual(images.map { $0.repeatsHero }, [nil, true])
        XCTAssertEqual(images.filter { $0.repeatsHero != true }.compactMap(\.imageURLString), [other])
        XCTAssertEqual(images.filter { $0.repeatsHero == true }.compactMap(\.imageURLString), [hero])
        XCTAssertEqual(article.allImageURLs.map(\.absoluteString), [hero, other])
    }

    func testUpgradingHeroNeverPromotesADifferentPhotoSharingOnlyATransformSegment() throws {
        let transform = "t_focal-260x130,f_avif,q_auto:best"
        let base = "https://media-cldnry.s-nbcnews.com/image/upload/\(transform)/rockcms/2026-10/"
        let heroFile = "251012-hurricane-isaias-damage-ac-1130p-8b1f3c.jpg"
        let otherFile = "251012-white-house-briefing-ac-1245p-2d9e7a.jpg"
        let pageURL = URL(string: "https://news.example/story")!
        let feed = "<img src=\"\(base)\(heroFile)?w=400\"/><p>First paragraph of the story, long enough to count.</p><p>Second paragraph of the story.</p>"
        let before = try ContentExtractor().extract(fromFeedHTML: feed, item: item(url: pageURL.absoluteString))
        func page(_ file: String) -> String {
            "<html><body><article><img srcset=\"\(base)\(file)?w=800 800w, \(base)\(file)?w=1800 1800w\"/><p>Body text that is long enough to be a paragraph of the story.</p></article></body></html>"
        }
        XCTAssertNil(ContentExtractor.upgradingHero(of: before, fromPageHTML: page(otherFile), pageURL: pageURL),
                     "the other photo shares only the transform segment")
        XCTAssertEqual(ContentExtractor.upgradingHero(of: before, fromPageHTML: page(heroFile), pageURL: pageURL)?.heroImageURL?.absoluteString,
                       "\(base)\(heroFile)?w=1800", "positive control: the same file offered wider is the upgrade")
    }

    func testHeroShownOnce_aBodyWithNoRepeatEncodesAsTheLiteralItEncodedToBeforeTheChange() throws {
        // A text-only feed body: no image, so no hero and no mark.
        let para1 = "<p>Paragraph number 1 carries enough words to be a real paragraph of the story body.</p>"
        let para2 = "<p>Paragraph number 2 carries enough words to be a real paragraph of the story body.</p>"
        let textOnly = try ContentExtractor().extract(fromFeedHTML: para1 + para2, item: item(url: "https://example.org/story"))
        XCTAssertNil(textOnly.heroImageURL)
        // The bytes the production encoder writes into the edition, key order pinned, against a hand-written literal.
        let textLiteral = """
        [{"kind":"paragraph","text":"Paragraph number 1 carries enough words to be a real paragraph of the story body."},\
        {"kind":"paragraph","text":"Paragraph number 2 carries enough words to be a real paragraph of the story body."}]
        """
        XCTAssertEqual(try CanonicalJSON.string(from: try BodyBlockJSON.encode(textOnly.bodyBlocks)), textLiteral)

        // A page whose og:image is a share card that is NOT in the body: a picture in the body, but nothing marked.
        let html = """
        <html><head><meta property="og:image" content="https://img.example.com/og/share-card.jpg"/></head>
        <body><div id="story">\(para1)
        <figure><img src="https://img.example.com/p/other-photo.jpg"/><figcaption>A caption.</figcaption></figure>
        \(para2)</div></body></html>
        """
        let config = SourceConfig(id: "test", name: "Test", feeds: [], strategy: .pageExtract, weight: 1.0,
                                  bodySelector: "#story", excludeURLPatterns: [], maxPerDay: 40)
        let url = URL(string: "https://news.example.com/story")!
        let page = try ContentExtractor().extract(fromPageHTML: html, articleURL: url, item: item(url: url.absoluteString), config: config)
        XCTAssertEqual(page.heroImageURL?.absoluteString, "https://img.example.com/og/share-card.jpg")
        let pageLiteral = """
        [{"kind":"paragraph","text":"Paragraph number 1 carries enough words to be a real paragraph of the story body."},\
        {"caption":"A caption.","imageURLString":"https://img.example.com/p/other-photo.jpg","kind":"image"},\
        {"kind":"paragraph","text":"Paragraph number 2 carries enough words to be a real paragraph of the story body."}]
        """
        XCTAssertEqual(try CanonicalJSON.string(from: try BodyBlockJSON.encode(page.bodyBlocks)), pageLiteral)
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
