import XCTest
@testable import AggregatorCore

/// The aggregator half of the "logo stamped on hero photos" fix.
///
/// The extraction rule itself lives in the app's ContentExtractor (vendored here byte-for-byte);
/// these tests prove the VENDORED copy behaves identically on the app's real Guardian fixtures,
/// and that the compiler -- the thing that actually downloads, resizes and re-hosts the hero --
/// fetches the article's own lead photograph instead of the signed, logo-stamped share card.
final class StampedHeroImageTests: XCTestCase {

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

    private static let guardianURL = "https://www.theguardian.com/uk-news/2026/oct/11/first-hampden-campaign-glasgow-scotland-football"
    private static let leadRendition = "https://i.guim.co.uk/img/media/b731ec571946e4165d394b1c0795936a11412d78/671_195_4433_3548/master/4433.jpg?width=700&dpr=2&s=none&crop=none"
    private static let stampedOG = "https://i.guim.co.uk/img/media/b731ec571946e4165d394b1c0795936a11412d78/671_195_4433_3548/master/4433.jpg?width=1200&height=630&quality=85&auto=format&fit=crop&precrop=40:21,offset-x50,offset-y0&overlay-align=bottom%2Cleft&overlay-width=100p&overlay-base64=L2ltZy9zdGF0aWMvb3ZlcmxheXMvdGctZGVmYXVsdC5wbmc&enable=upscale&s=8a9c13271af5e83b3ed06cdb5577794a"

    private func guardianConfig() throws -> SourceConfig {
        try XCTUnwrap(SourceCatalog.all.first { $0.id == "guardian" }, "guardian missing from vendored SourceCatalog")
    }

    private func item(_ url: String) -> FeedItem {
        FeedItem(guid: url, url: URL(string: url)!, title: "Fixture", summary: nil,
                 publishedAt: nil, feedCategories: [], contentHTML: nil, imageURLs: [])
    }

    // MARK: - vendored extractor parity

    func testVendoredExtractorReplacesTheStampedShareCardWithTheLeadPhoto() throws {
        let html = try fixture("page-guardian-stamped-og.html")
        let url = URL(string: Self.guardianURL)!
        let extracted = try ContentExtractor().extract(fromPageHTML: html, articleURL: url,
                                                       item: item(Self.guardianURL), config: try guardianConfig())
        XCTAssertEqual(extracted.heroImageURL?.absoluteString, Self.leadRendition)
        XCTAssertFalse(extracted.heroImageURL?.absoluteString.contains("overlay") ?? true)
        // Lead photo appears once: hero first, then the one inline photo.
        XCTAssertEqual(extracted.allImageURLs.count, 2)
        XCTAssertEqual(extracted.bodyBlocks.filter { $0.kind == .image }.count, 1)
        // The one inline photo is a different photograph from the lead: no mark.
        XCTAssertNil(extracted.bodyBlocks.first { $0.kind == .image }?.repeatsHero)
    }

    /// NEGATIVE CONTROL (vendored copy): a page whose og:image is clean keeps it, even though a
    /// lead figure is present.
    func testVendoredExtractorKeepsACleanOgImage() throws {
        var html = try fixture("page-guardian-stamped-og.html")
        let range = try XCTUnwrap(html.range(of: Self.stampedOG))
        html.replaceSubrange(range, with: "https://i.guim.co.uk/img/media/b731ec571946e4165d394b1c0795936a11412d78/671_195_4433_3548/master/4433.jpg?width=1200&quality=85&s=clean")
        let url = URL(string: Self.guardianURL)!
        let extracted = try ContentExtractor().extract(fromPageHTML: html, articleURL: url,
                                                       item: item(Self.guardianURL), config: try guardianConfig())
        XCTAssertEqual(extracted.heroImageURL?.absoluteString,
                       "https://i.guim.co.uk/img/media/b731ec571946e4165d394b1c0795936a11412d78/671_195_4433_3548/master/4433.jpg?width=1200&quality=85&s=clean")
    }

    // MARK: - BBC badge (vendored extractor parity on the real captures)

    private func bbcConfig() throws -> SourceConfig {
        try XCTUnwrap(SourceCatalog.all.first { $0.id == "bbc" }, "bbc missing from vendored SourceCatalog")
    }

    private func extractBBC(_ fixtureName: String) throws -> ExtractedArticle {
        let url = URL(string: "https://www.bbc.co.uk/news/articles/x")!
        return try ContentExtractor().extract(fromPageHTML: try fixture(fixtureName), articleURL: url,
                                              item: item(url.absoluteString), config: try bbcConfig())
    }

    /// The og:image of every BBC article is a `branded_news`/`branded_sport` share card with a badge burned in.
    func testVendoredExtractorDropsTheBBCBadge_andMarksTheBodyCopyOfTheHeroPhoto() throws {
        // No lead figure (the first figure is a video): the badge-free `standard/1200` twin of the og asset is the
        // hero, and the body's HSI photo (same asset, standard/1680) is marked as its repeat, caption kept.
        let omar = try extractBBC("page-bbc-lead-photo-after-paragraphs.html")
        XCTAssertEqual(omar.heroImageURL?.absoluteString,
                       "https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/dc45/live/01c4d970-c64f-11f1-b47f-e3f9cf703bc3.png")
        let omarMarked = omar.bodyBlocks.filter { $0.repeatsHero == true }
        XCTAssertEqual(omarMarked.count, 1)
        XCTAssertEqual(omarMarked.first?.caption, "HSI agents loading a box outside the residence")
        XCTAssertEqual(omar.bodyBlocks.filter { $0.kind == .image && $0.repeatsHero != true }.count, 1, "the portrait")

        // Video-led story whose og photo is not in the body: the twin, nothing marked, no mid-article image promoted.
        let noLead = try extractBBC("page-bbc-no-lead-photo.html")
        XCTAssertEqual(noLead.heroImageURL?.absoluteString,
                       "https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/2165/live/f588e620-c602-11f1-9a39-31b474234113.jpg")
        XCTAssertTrue(noLead.bodyBlocks.allSatisfy { $0.repeatsHero == nil })

        // BBC Sport (`branded_sport`): the lead figure's own rendition; the 3840 px copy is marked, never downloaded.
        let sport = try extractBBC("page-bbc-sport-branded.html")
        XCTAssertEqual(sport.heroImageURL?.absoluteString,
                       "https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/779a/live/b7058b10-c616-11f1-bc2e-018d645d8d21.jpg")
        XCTAssertEqual(sport.bodyBlocks.filter { $0.repeatsHero == true }.count, 1)
        XCTAssertEqual(sport.allImageURLs, [sport.heroImageURL!])
    }

    /// NEGATIVE CONTROL: a BBC rendition that is not a `branded_*` card is left exactly as it is (the hero stays the
    /// og:image), and a non-BBC host with a `branded_news` path segment is nobody's stamp.
    func testBBCRuleKeysOnTheBrandedSegmentAndTheBBCHostOnly() throws {
        func stamped(_ s: String) -> Bool { ContentExtractor.isStampedSocialImage(URL(string: s)!) }
        XCTAssertTrue(stamped("https://ichef.bbci.co.uk/ace/branded_news/1200/cpsprodpb/13bb/live/x.jpg"))
        XCTAssertTrue(stamped("https://ichef.bbci.co.uk/ace/branded_sport/1200/cpsprodpb/779a/live/x.jpg"))
        XCTAssertFalse(stamped("https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/13bb/live/x.jpg"))
        XCTAssertFalse(stamped("https://cdn.example.com/ace/branded_news/1200/cpsprodpb/13bb/live/x.jpg"))
        XCTAssertEqual(ContentExtractor.unstampedTwin(of: URL(string: "https://ichef.bbci.co.uk/ace/branded_news/1200/cpsprodpb/13bb/live/x.jpg")!)?.absoluteString,
                       "https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/13bb/live/x.jpg", "width is kept, never changed")
        XCTAssertNil(ContentExtractor.unstampedTwin(of: URL(string: "https://i.guim.co.uk/img/media/a/b/master/4433.jpg?width=1200&overlay-base64=AAAA&s=x")!),
                     "Guardian's stamp is a signed query parameter: no twin can be derived")
        XCTAssertNil(ContentExtractor.unstampedTwin(of: URL(string: "https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/13bb/live/x.jpg")!))
    }

    // MARK: - end to end through the compiler

    private var outDir: URL!
    private var stateURL: URL!
    private let now = Date(timeIntervalSince1970: 1_785_931_200) // 2026-08-05T12:00:00Z

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stamped-hero-\(UUID().uuidString)")
        outDir = root.appendingPathComponent("out")
        stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        DiagnosticsLog.shared.isSilenced = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outDir.deletingLastPathComponent())
        DiagnosticsLog.shared.isSilenced = false
    }

    private func rfc822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.string(from: date)
    }

    /// A Guardian-shaped source (page extraction, `#maincontent`) pointing at stubbed hosts.
    private func compile(pageHTML: String, client: FakeHTTPClient) async throws -> Edition {
        let feedURL = "https://news.example/feed"
        let pageURL = "https://news.example/world/2026/aug/05/story"
        let longParagraph = "City officials confirmed the plan on Monday after months of public hearings and detailed negotiations with neighborhood groups across the area, promising further updates as the work proceeds through the fall season and beyond."
        // The real fixture has four short paragraphs; pad the body so the article gate passes.
        let padded = pageHTML.replacingOccurrences(
            of: "<div class=\"article-body-commercial-selector article-body-viewer-selector dcr-1quntsr\">",
            with: "<div class=\"article-body-commercial-selector article-body-viewer-selector dcr-1quntsr\"><p>\(longParagraph)</p><p>\(longParagraph)</p><p>\(longParagraph)</p>")
        client.stubs[feedURL] = .init(data: Data("""
            <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>News</title>
            <item><title>Hampden</title><link>\(pageURL)</link><guid>hampden-1</guid>
            <pubDate>\(rfc822(now.addingTimeInterval(-3600)))</pubDate></item></channel></rss>
            """.utf8), etag: nil, lastModified: nil)
        client.stubs[pageURL] = .init(data: Data(padded.utf8), etag: nil, lastModified: nil)

        let catalog = [SourceConfig(id: "news", name: "News", feeds: [
            FeedEndpoint(url: URL(string: feedURL)!, defaultCategory: .world)
        ], strategy: .pageExtract, weight: 1.0, bodySelector: "#maincontent", excludeURLPatterns: [], maxPerDay: 40)]
        let configuration = CompilerConfiguration(baseURL: "https://pages.example/edition", outDirectory: outDir,
                                                  stateFileURL: stateURL, now: { self.now })
        _ = try await EditionCompiler(catalog: catalog, client: client, resizer: FakeResizer(),
                                      configuration: configuration).run()
        let result = try ProcessRunner.run(["gunzip", "-c", outDir.appendingPathComponent("edition.json.gz").path])
        XCTAssertEqual(result.status, 0, result.stderrText)
        return try JSONDecoder().decode(Edition.self, from: result.stdout)
    }

    private func expectedSHA16(forRaw raw: String) -> String {
        var resized = Data("RESIZED:".utf8)
        resized.append(Data(raw.utf8))
        return SHA256.hexDigest16(resized)
    }

    func testCompilerDownloadsTheLeadPhotoNotTheLogoStampedShareCard() async throws {
        let client = FakeHTTPClient()
        client.stubs[Self.leadRendition] = .init(data: Data("LEADPHOTOBYTES".utf8), etag: nil, lastModified: nil)
        client.stubs[Self.stampedOG] = .init(data: Data("STAMPEDSHARECARDBYTES".utf8), etag: nil, lastModified: nil)

        let edition = try await compile(pageHTML: try fixture("page-guardian-stamped-og.html"), client: client)

        XCTAssertEqual(edition.articles.count, 1)
        XCTAssertEqual(client.requestCount(of: Self.stampedOG), 0, "the logo-stamped share card must never be downloaded")
        XCTAssertEqual(client.requestCount(of: Self.leadRendition), 1)
        XCTAssertEqual(edition.articles[0].topImageURL,
                       "https://pages.example/edition/images/\(expectedSHA16(forRaw: "LEADPHOTOBYTES")).jpg")
    }

    /// NEGATIVE CONTROL (compiler level): with a clean og:image the compiler still downloads the
    /// og:image exactly as before and never goes looking for the lead figure.
    func testCompilerStillDownloadsACleanOgImage() async throws {
        let cleanOG = "https://i.guim.co.uk/img/media/b731ec571946e4165d394b1c0795936a11412d78/671_195_4433_3548/master/4433.jpg?width=1200&quality=85&s=clean"
        var html = try fixture("page-guardian-stamped-og.html")
        html.replaceSubrange(try XCTUnwrap(html.range(of: Self.stampedOG)), with: cleanOG)
        let client = FakeHTTPClient()
        client.stubs[cleanOG] = .init(data: Data("CLEANOGBYTES".utf8), etag: nil, lastModified: nil)
        client.stubs[Self.leadRendition] = .init(data: Data("LEADPHOTOBYTES".utf8), etag: nil, lastModified: nil)

        let edition = try await compile(pageHTML: html, client: client)

        XCTAssertEqual(client.requestCount(of: cleanOG), 1)
        XCTAssertEqual(client.requestCount(of: Self.leadRendition), 0)
        XCTAssertEqual(edition.articles[0].topImageURL,
                       "https://pages.example/edition/images/\(expectedSHA16(forRaw: "CLEANOGBYTES")).jpg")
    }

    // MARK: - BBC end to end

    /// A BBC-shaped source (the real catalog entry's selectors) pointing at stubbed hosts.
    private func compileBBC(pageHTML: String, client: FakeHTTPClient) async throws -> Edition {
        let feedURL = "https://news.example/feed"
        let pageURL = "https://news.example/news/articles/cr93znyk44e1o"
        client.stubs[feedURL] = .init(data: Data("""
            <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>News</title>
            <item><title>Saudi capital airport hit</title><link>\(pageURL)</link><guid>bbc-1</guid>
            <pubDate>\(rfc822(now.addingTimeInterval(-3600)))</pubDate></item></channel></rss>
            """.utf8), etag: nil, lastModified: nil)
        client.stubs[pageURL] = .init(data: Data(pageHTML.utf8), etag: nil, lastModified: nil)
        let bbc = try bbcConfig()
        let catalog = [SourceConfig(id: "bbc", name: "BBC News", feeds: [
            FeedEndpoint(url: URL(string: feedURL)!, defaultCategory: .world)
        ], strategy: .pageExtract, weight: 1.0, bodySelector: bbc.bodySelector, excludeURLPatterns: [],
                                    maxPerDay: 40, junkSelectors: bbc.junkSelectors)]
        let configuration = CompilerConfiguration(baseURL: "https://pages.example/edition", outDirectory: outDir,
                                                  stateFileURL: stateURL, now: { self.now })
        _ = try await EditionCompiler(catalog: catalog, client: client, resizer: FakeResizer(),
                                      configuration: configuration).run()
        let result = try ProcessRunner.run(["gunzip", "-c", outDir.appendingPathComponent("edition.json.gz").path])
        XCTAssertEqual(result.status, 0, result.stderrText)
        return try JSONDecoder().decode(Edition.self, from: result.stdout)
    }

    func testCompilerDownloadsTheBadgeFreeTwinNotTheBBCNewsShareCard() async throws {
        let branded = "https://ichef.bbci.co.uk/ace/branded_news/1200/cpsprodpb/dc45/live/01c4d970-c64f-11f1-b47f-e3f9cf703bc3.png"
        let twin = "https://ichef.bbci.co.uk/ace/standard/1200/cpsprodpb/dc45/live/01c4d970-c64f-11f1-b47f-e3f9cf703bc3.png"
        let client = FakeHTTPClient()
        client.stubs[branded] = .init(data: Data("BADGEDCARD".utf8), etag: nil, lastModified: nil)
        client.stubs[twin] = .init(data: Data("TWINPHOTO".utf8), etag: nil, lastModified: nil)

        let edition = try await compileBBC(pageHTML: try fixture("page-bbc-lead-photo-after-paragraphs.html"), client: client)

        XCTAssertEqual(edition.articles.count, 1)
        XCTAssertEqual(client.requestCount(of: branded), 0, "the badged share card must never be downloaded")
        XCTAssertEqual(client.requestCount(of: twin), 1)
        XCTAssertEqual(edition.articles[0].topImageURL,
                       "https://pages.example/edition/images/\(expectedSHA16(forRaw: "TWINPHOTO")).jpg")
        // The published body carries the mark on the one block that shows the hero photo, with its caption.
        let blocks = try JSONDecoder().decode([BodyBlock].self, from: Data(edition.articles[0].bodyBlocksJSON.utf8))
        let marked = blocks.filter { $0.repeatsHero == true }
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.caption, "HSI agents loading a box outside the residence")
        XCTAssertTrue(edition.articles[0].bodyBlocksJSON.contains("\"repeatsHero\":true"))
    }
}
