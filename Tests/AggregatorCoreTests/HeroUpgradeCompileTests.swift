import XCTest
@testable import AggregatorCore

/// Feed-text sources whose FEED carries only a small lead photo (Sun-Times/WBEZ 840 px, ProPublica 1149, Block Club
/// 1024) get their hero swapped for the wider rendition of the SAME photo the article page publishes. These tests
/// drive the real compiler end to end (fake HTTP, real vendored extractor, the app's real Sun-Times page fixture).
final class HeroUpgradeCompileTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BroadsheetTests/Fixtures")
    }

    private static let feedHero = "https://cst.brightspotcdn.com/dims4/default/3f7d227/2147483647/strip/true/crop/6214x4143+0+0/resize/840x560!/quality/90/?url=https%3A%2F%2Fchorus-production-cst-web.s3.us-east-1.amazonaws.com%2Fbrightspot%2Fe1%2F58%2F6eba083945d3afd18f1d87036dc8%2Fap26284815413474.jpg"
    private static let pageHero = "https://cst.brightspotcdn.com/dims4/default/bb13081/2147483647/strip/false/crop/6214x4143+0+0/resize/1486x991!/quality/90/?url=https%3A%2F%2Fchorus-production-cst-web.s3.us-east-1.amazonaws.com%2Fbrightspot%2Fe1%2F58%2F6eba083945d3afd18f1d87036dc8%2Fap26284815413474.jpg"
    private static let feedURL = "https://news.example/rss/index.xml"
    private static let pageURL = "https://news.example/nfl/2026/10/11/lions-offense-romps"

    private var outDir: URL!
    private var stateURL: URL!
    private let now = Date(timeIntervalSince1970: 1_785_931_200)

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-upgrade-\(UUID().uuidString)")
        outDir = root.appendingPathComponent("out")
        stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        DiagnosticsLog.shared.isSilenced = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outDir.deletingLastPathComponent())
        DiagnosticsLog.shared.isSilenced = false
    }

    private let paragraph = "City officials confirmed the plan on Monday after months of public hearings and detailed negotiations with neighborhood groups across the area, promising further updates as the work proceeds through the fall season and beyond."

    private func rfc822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.string(from: date)
    }

    /// A feed-text source `id` with one item whose content is the lead <img> (the feed's small rendition) + paragraphs.
    private func compile(sourceID: String, paragraphs: Int = 3, client: FakeHTTPClient) async throws -> (Edition, SourceRunStats?) {
        let body = "<img src=\"\(Self.feedHero.replacingOccurrences(of: "&", with: "&amp;"))\"/>" +
            String(repeating: "<p>\(paragraph)</p>", count: paragraphs)
        client.stubs[Self.feedURL] = .init(data: Data("""
            <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>News</title>
            <item><title>Lions romp</title><link>\(Self.pageURL)</link><guid>lions-1</guid>
            <pubDate>\(rfc822(now.addingTimeInterval(-3600)))</pubDate>
            <content:encoded><![CDATA[\(body)]]></content:encoded></item></channel></rss>
            """.utf8), etag: nil, lastModified: nil)
        let catalog = [SourceConfig(id: sourceID, name: "News", feeds: [
            FeedEndpoint(url: URL(string: Self.feedURL)!, defaultCategory: .chicago)
        ], strategy: .feedFullText, weight: 1.0, bodySelector: nil, excludeURLPatterns: [], maxPerDay: 40)]
        let configuration = CompilerConfiguration(baseURL: "https://pages.example/edition", outDirectory: outDir,
                                                  stateFileURL: stateURL, now: { self.now })
        let stats = try await EditionCompiler(catalog: catalog, client: client, resizer: FakeResizer(),
                                              configuration: configuration).run()
        let result = try ProcessRunner.run(["gunzip", "-c", outDir.appendingPathComponent("edition.json.gz").path])
        return (try JSONDecoder().decode(Edition.self, from: result.stdout), stats.perSource.first { $0.sourceID == sourceID })
    }

    private func stubbedClient(page: Bool = true) throws -> FakeHTTPClient {
        let client = FakeHTTPClient()
        if page {
            let html = try String(contentsOf: fixturesDir.appendingPathComponent("page-suntimes-lead.html"), encoding: .utf8)
            client.stubs[Self.pageURL] = .init(data: Data(html.utf8), etag: nil, lastModified: nil)
        }
        client.stubs[Self.feedHero] = .init(data: Data("FEEDHERO840".utf8), etag: nil, lastModified: nil)
        client.stubs[Self.pageHero] = .init(data: Data("PAGEHERO1486".utf8), etag: nil, lastModified: nil)
        return client
    }

    private func sha16(of raw: String) -> String {
        var resized = Data("RESIZED:".utf8)
        resized.append(Data(raw.utf8))
        return SHA256.hexDigest16(resized)
    }

    func testOptedInSourceDownloadsThePageRenditionNotTheFeedPhoto() async throws {
        let client = try stubbedClient()
        let (edition, stats) = try await compile(sourceID: "suntimes", client: client)

        XCTAssertEqual(edition.articles.count, 1)
        XCTAssertEqual(client.requestCount(of: Self.pageURL), 1)
        XCTAssertEqual(client.requestCount(of: Self.pageHero), 1)
        XCTAssertEqual(client.requestCount(of: Self.feedHero), 0, "the small feed rendition is never downloaded")
        XCTAssertEqual(edition.articles[0].topImageURL, "https://pages.example/edition/images/\(sha16(of: "PAGEHERO1486")).jpg")
        XCTAssertEqual(stats?.heroUpgrades, 1)
        // CHANGED (hero shown once): the feed's own copy of the lead no longer LEAVES the body. It stays, marked
        // `repeatsHero`, so the reader draws the photo once (as the hero) and the block's caption/credit survive.
        let blocks = try JSONDecoder().decode([BodyBlock].self, from: Data(edition.articles[0].bodyBlocksJSON.utf8))
        XCTAssertEqual(blocks.filter { $0.kind == .image }.map(\.repeatsHero), [true])
        XCTAssertEqual(blocks.filter { $0.kind == .paragraph }.count, 3)
    }

    /// NEGATIVE CONTROL: the identical item under a source that is NOT opted in keeps the feed's hero and never
    /// fetches the article page.
    func testASourceThatIsNotOptedInIsUntouched() async throws {
        let client = try stubbedClient()
        let (edition, stats) = try await compile(sourceID: "wire", client: client)

        XCTAssertEqual(client.requestCount(of: Self.pageURL), 0)
        XCTAssertEqual(client.requestCount(of: Self.feedHero), 1)
        XCTAssertEqual(edition.articles[0].topImageURL, "https://pages.example/edition/images/\(sha16(of: "FEEDHERO840")).jpg")
        XCTAssertEqual(stats?.heroUpgrades, 0)
        let blocks = try JSONDecoder().decode([BodyBlock].self, from: Data(edition.articles[0].bodyBlocksJSON.utf8))
        XCTAssertEqual(blocks.filter { $0.kind == .image }.count, 1, "the lead stays in the body exactly as before")
        XCTAssertEqual(blocks.filter { $0.kind == .image }.first?.repeatsHero, true,
                       "and, being the hero (the first body image of a feed-text article), it is marked as the hero's repeat")
    }

    func testAFailedPageFetchKeepsTheFeedHeroAndNeverFailsTheArticle() async throws {
        let client = try stubbedClient(page: false) // page answers 404
        let (edition, stats) = try await compile(sourceID: "suntimes", client: client)

        XCTAssertEqual(edition.articles.count, 1)
        XCTAssertEqual(edition.articles[0].topImageURL, "https://pages.example/edition/images/\(sha16(of: "FEEDHERO840")).jpg")
        XCTAssertEqual(stats?.heroUpgrades, 0)
        XCTAssertEqual(stats?.failures, 0)
    }

    func testNoPageIsFetchedForAnArticleTheGateRejects() async throws {
        let client = try stubbedClient()
        let (edition, stats) = try await compile(sourceID: "suntimes", paragraphs: 1, client: client)

        XCTAssertEqual(edition.articles.count, 0)
        XCTAssertEqual(stats?.gateRejected, 1)
        XCTAssertEqual(client.requestCount(of: Self.pageURL), 0)
    }

    func testTheOptInSetIsExactlyTheFourSourcesMeasured() {
        XCTAssertEqual(EditionCompiler.pageHeroUpgradeSourceIDs, ["suntimes", "wbez", "propublica", "blockclub"])
        // ...and every one of them is a real feed-text source in the catalog.
        for id in EditionCompiler.pageHeroUpgradeSourceIDs {
            XCTAssertEqual(SourceCatalog.all.first { $0.id == id }?.strategy, .feedFullText, id)
        }
    }
}
