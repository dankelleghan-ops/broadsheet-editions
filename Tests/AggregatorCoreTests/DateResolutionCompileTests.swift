import XCTest
@testable import AggregatorCore

/// Real publish dates in the edition (2026-10-12). Before: an item the feed parser could read no date from was stamped
/// with the compile time (`item.publishedAt ?? now`) -- NBC 5 (zone-less feed dates), the Sun-Times and WBEZ
/// (fractional-second ISO dates) -- which showed days-old stories as "0 min ago". Now: the feed's date, else the page's
/// own `datePublished`, else (last resort) the compile time FLAGGED `dateIsEstimated`; and an already-compiled article
/// whose stored date was such a guess is corrected when the feed carries the real one.
final class DateResolutionCompileTests: XCTestCase {

    private var root: URL!
    private var outDir: URL!
    private var stateURL: URL!
    /// Fixed "now": 2026-10-12T00:30:00Z.
    private let now0 = Date(timeIntervalSince1970: 1_791_765_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("date-res-\(UUID().uuidString)")
        outDir = root.appendingPathComponent("out")
        stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        DiagnosticsLog.shared.isSilenced = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        DiagnosticsLog.shared.isSilenced = false
    }

    private let paragraph = "City officials confirmed the plan on Monday after months of public hearings and detailed negotiations with neighborhood groups across the area, promising further updates as the work proceeds through the fall season and beyond."
    private let feedURL = "https://news.example/feed"
    private let pageURL = "https://news.example/story-1"

    private func page(datePublished: String?, extraHead: String = "") -> String {
        let ld = datePublished.map { "<script type=\"application/ld+json\">{\"@type\":\"NewsArticle\",\"dateModified\":\"2026-10-12T00:10:00Z\",\"datePublished\":\"\($0)\"}</script>" } ?? ""
        return "<html><head>\(ld)\(extraHead)</head><body><div id=\"body\"><p>\(paragraph)</p><p>\(paragraph)</p><p>\(paragraph)</p></div></body></html>"
    }

    private func rssFeed(pubDate: String?) -> String {
        let date = pubDate.map { "<pubDate>\($0)</pubDate>" } ?? ""
        return "<?xml version=\"1.0\"?><rss version=\"2.0\" xmlns:content=\"http://purl.org/rss/1.0/modules/content/\"><channel><title>N</title>"
            + "<item><title>Story</title><link>\(pageURL)</link><guid>story-1</guid>\(date)"
            + "<content:encoded><![CDATA[<p>\(paragraph)</p><p>\(paragraph)</p><p>\(paragraph)</p>]]></content:encoded></item></channel></rss>"
    }

    private func source(id: String = "news", strategy: FetchStrategy, zone: TimeZone? = nil) -> SourceConfig {
        SourceConfig(id: id, name: "News", feeds: [FeedEndpoint(url: URL(string: feedURL)!, defaultCategory: .chicago,
                                                                 zonelessDatesTimeZone: zone)],
                     strategy: strategy, weight: 1.0, bodySelector: strategy == .pageExtract ? "#body" : nil,
                     excludeURLPatterns: [], maxPerDay: 40)
    }

    @discardableResult
    private func run(_ source: SourceConfig, feed: String, page: String?, at now: Date, client: FakeHTTPClient = FakeHTTPClient())
        async throws -> (stats: RunStats, edition: Edition, rawJSON: String, client: FakeHTTPClient) {
        client.stubs[feedURL] = .init(data: Data(feed.utf8), etag: nil, lastModified: nil)
        if let page { client.stubs[pageURL] = .init(data: Data(page.utf8), etag: nil, lastModified: nil) }
        let configuration = CompilerConfiguration(baseURL: "https://pages.example/edition", outDirectory: outDir,
                                                  stateFileURL: stateURL, now: { now })
        let stats = try await EditionCompiler(catalog: [source], client: client, resizer: FakeResizer(),
                                              configuration: configuration).run()
        let gz = outDir.appendingPathComponent("edition.json.gz").path
        let result = try ProcessRunner.run(["gunzip", "-c", gz])
        let edition = try JSONDecoder().decode(Edition.self, from: result.stdout)
        return (stats, edition, String(decoding: result.stdout, as: UTF8.self), client)
    }

    private func iso(_ date: Date) -> String { EditionDates.string(from: date) }

    // MARK: the feed's own date

    func testZonelessFeedDateWithADeclaredZoneIsReadAndNotFlagged() async throws {
        // NBC 5: `Sun, Oct 11 2026 04:04:04 PM` is Chicago time -> 2026-10-11T21:04:04Z.
        let r = try await run(source(strategy: .pageExtract, zone: TimeZone(identifier: "America/Chicago")),
                              feed: rssFeed(pubDate: "Sun, Oct 11 2026 04:04:04 PM"), page: page(datePublished: nil), at: now0)
        XCTAssertEqual(r.edition.articles.count, 1)
        XCTAssertEqual(r.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z")
        XCTAssertNil(r.edition.articles[0].dateIsEstimated)
        XCTAssertFalse(r.rawJSON.contains("dateIsEstimated"), "the key is omitted for a real date")
        XCTAssertEqual(r.stats.perSource[0].datesEstimated, 0)
    }

    func testFractionalSecondIsoFeedDateIsRead() async throws {
        let feed = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>N</title>
        <entry><title>Story</title><id>story-1</id><link rel="alternate" href="\(pageURL)"/>
        <published>2026-10-11T18:47:41.046-05:00</published>
        <content type="html">&lt;p&gt;\(paragraph)&lt;/p&gt;&lt;p&gt;\(paragraph)&lt;/p&gt;&lt;p&gt;\(paragraph)&lt;/p&gt;</content></entry></feed>
        """
        let r = try await run(source(strategy: .feedFullText), feed: feed, page: nil, at: now0)
        XCTAssertEqual(r.edition.articles[0].publishedAt, "2026-10-11T23:47:41Z")
        XCTAssertEqual(r.client.requestCount(of: pageURL), 0, "a feed that carries a date costs no page request")
    }

    // MARK: the page's date, then the guess

    func testUndatedFeedItemTakesThePagesOriginalPublishTime() async throws {
        let r = try await run(source(strategy: .pageExtract), feed: rssFeed(pubDate: nil),
                              page: page(datePublished: "2026-10-11T16:04:04-05:00"), at: now0)
        XCTAssertEqual(r.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z", "datePublished, not the page's dateModified")
        XCTAssertNil(r.edition.articles[0].dateIsEstimated)
        XCTAssertEqual(r.stats.perSource[0].datesFromPage, 1)
        XCTAssertEqual(r.stats.perSource[0].datesEstimated, 0)
    }

    func testNoDateAnywhereIsStampedWithNowAndFlagged() async throws {
        let r = try await run(source(strategy: .pageExtract), feed: rssFeed(pubDate: nil), page: page(datePublished: nil), at: now0)
        XCTAssertEqual(r.edition.articles[0].publishedAt, iso(now0))
        XCTAssertEqual(r.edition.articles[0].dateIsEstimated, true)
        XCTAssertTrue(r.rawJSON.contains("\"dateIsEstimated\":true"))
        XCTAssertEqual(r.stats.perSource[0].datesEstimated, 1)
        XCTAssertTrue(CompileEditionMain.report(r.stats).contains("DATES ESTIMATED"))
        XCTAssertTrue(CompileEditionMain.report(r.stats).contains("dates: 1 estimated this run (news=1)"))
    }

    func testAnUndatedFeedTextItemFetchesItsPageOnceForTheDate() async throws {
        let r = try await run(source(strategy: .feedFullText), feed: rssFeed(pubDate: nil),
                              page: page(datePublished: "2026-10-11T16:04:04-05:00"), at: now0)
        XCTAssertEqual(r.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z")
        XCTAssertEqual(r.client.requestCount(of: pageURL), 1)
    }

    func testTheHeroUpgradeAndTheDateShareOnePageRequest() async throws {
        // An opted-in source (suntimes) with an undated item and a lead photo needs the page for both: ONE request.
        let hero = "https://cst.brightspotcdn.com/dims4/default/3f7d227/2147483647/strip/true/crop/6214x4143+0+0/resize/840x560!/quality/90/?url=https%3A%2F%2Fchorus-production-cst-web.s3.us-east-1.amazonaws.com%2Fbrightspot%2Fe1%2F58%2F6eba083945d3afd18f1d87036dc8%2Fap26284815413474.jpg"
        let feed = rssFeed(pubDate: nil).replacingOccurrences(of: "<![CDATA[", with: "<![CDATA[<img src=\"\(hero)\"/>")
        let client = FakeHTTPClient()
        client.stubs[hero] = .init(data: Data("HERO".utf8), etag: nil, lastModified: nil)
        let r = try await run(source(id: "suntimes", strategy: .feedFullText), feed: feed,
                              page: page(datePublished: "2026-10-11T16:04:04-05:00"), at: now0, client: client)
        XCTAssertEqual(r.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z")
        XCTAssertEqual(r.client.requestCount(of: pageURL), 1)
    }

    func testAnUndatedItemWhosePageDateIsOlderThanTheWindowIsSkippedAndNotRefetched() async throws {
        let old = page(datePublished: "2026-10-05T12:00:00Z")
        let first = try await run(source(strategy: .pageExtract), feed: rssFeed(pubDate: nil), page: old, at: now0)
        XCTAssertEqual(first.edition.articles.count, 0)
        XCTAssertEqual(first.stats.perSource[0].staleByPageDate, 1)
        // A second run: the URL is negative-cached, so the page is not fetched again.
        let second = try await run(source(strategy: .pageExtract), feed: rssFeed(pubDate: nil), page: old,
                                   at: now0.addingTimeInterval(1800))
        XCTAssertEqual(second.edition.articles.count, 0)
        XCTAssertEqual(second.client.requestCount(of: pageURL), 0)
    }

    // MARK: articles compiled before the fix

    private func legacyState(guid: String, publishedAt: Date, estimated: Bool?) throws {
        // A state file as an OLD compiler wrote it (no dateIsEstimated key at all) when `estimated == nil`.
        var state = CompilerState()
        state.articles = [CompiledArticle(guid: guid, url: pageURL, sourceID: "news", title: "Story", author: nil, attribution: nil,
                                          publishedAt: publishedAt, dateIsEstimated: estimated,
                                          bodyBlocksJSON: "[{\"kind\":\"paragraph\",\"text\":\"\(paragraph)\"}]",
                                          imageSHA16: nil, imageSourceURL: nil)]
        try state.save(to: stateURL)
    }

    func testAnOldStateFileWithoutTheFieldStillLoads() throws {
        try legacyState(guid: "story-1", publishedAt: now0, estimated: nil)
        let text = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(text.contains("dateIsEstimated"), "nil is not written, so this is exactly an old-format file")
        XCTAssertEqual(CompilerState.load(from: stateURL).articles.count, 1)
        XCTAssertNil(CompilerState.load(from: stateURL).articles[0].dateIsEstimated)
    }

    func testARetainedGuessedDateIsCorrectedInPlaceWithoutDuplicatingOrDropping() async throws {
        // Compiled earlier with a first-seen stamp (an old compiler): stored 2026-10-12T00:00:00Z, really published
        // 2026-10-11T21:04:04Z (still inside the window).
        let stamp = now0.addingTimeInterval(-1800)
        try legacyState(guid: "story-1", publishedAt: stamp, estimated: nil)
        let r = try await run(source(strategy: .feedFullText),
                              feed: rssFeed(pubDate: "Sun, 11 Oct 2026 21:04:04 GMT"), page: nil, at: now0)
        XCTAssertEqual(r.edition.articles.count, 1, "same guid: not duplicated, not dropped")
        XCTAssertEqual(r.edition.articles[0].guid, "story-1")
        XCTAssertEqual(r.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z")
        XCTAssertEqual(r.stats.perSource[0].datesCorrected, 1)
        XCTAssertEqual(r.stats.perSource[0].newArticles, 0, "it was never re-compiled")
        XCTAssertEqual(r.client.requestCount(of: pageURL), 0, "and never re-fetched")
        XCTAssertEqual(CompilerState.load(from: stateURL).articles.map(\.publishedAt), [Date(timeIntervalSince1970: 1_791_752_644)])
        XCTAssertEqual(CompilerState.load(from: stateURL).articles[0].dateIsEstimated, false)
        // A later run is stable: nothing left to correct.
        let again = try await run(source(strategy: .feedFullText), feed: rssFeed(pubDate: "Sun, 11 Oct 2026 21:04:04 GMT"),
                                  page: nil, at: now0.addingTimeInterval(1800))
        XCTAssertEqual(again.edition.articles.count, 1)
        XCTAssertEqual(again.stats.perSource[0].datesCorrected, 0)
    }

    func testACorrectedDateOutsideTheWindowLeavesTheEditionAndIsNotReAdded() async throws {
        // Stamped as if brand new, but the feed says it was published 6 days ago: a days-old recap shown as "0 min ago".
        try legacyState(guid: "story-1", publishedAt: now0.addingTimeInterval(-1800), estimated: true)
        let stale = rssFeed(pubDate: "Tue, 06 Oct 2026 12:00:00 GMT")
        let first = try await run(source(strategy: .feedFullText), feed: stale, page: nil, at: now0)
        XCTAssertEqual(first.edition.articles.count, 0, "it was never inside the window")
        XCTAssertEqual(first.stats.perSource[0].datesCorrected, 1)
        let second = try await run(source(strategy: .feedFullText), feed: stale, page: nil, at: now0.addingTimeInterval(1800))
        XCTAssertEqual(second.edition.articles.count, 0, "and the same cutoff keeps it out; it is not re-added as 'new'")
        XCTAssertEqual(second.stats.perSource[0].newArticles, 0)
    }

    /// NEGATIVE CONTROL: real dates are never touched -- not by a feed that bumps its pubDate on an update (a LATER
    /// date), and not by one that disagrees by seconds.
    func testRealDatedArticlesAreNeverRewritten() async throws {
        let first = try await run(source(strategy: .feedFullText), feed: rssFeed(pubDate: "Sun, 11 Oct 2026 21:04:04 GMT"),
                                  page: nil, at: now0)
        XCTAssertEqual(first.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z")
        let bumped = try await run(source(strategy: .feedFullText), feed: rssFeed(pubDate: "Sun, 11 Oct 2026 23:59:00 GMT"),
                                   page: nil, at: now0.addingTimeInterval(1800))
        XCTAssertEqual(bumped.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z")
        let earlier = try await run(source(strategy: .feedFullText), feed: rssFeed(pubDate: "Sun, 11 Oct 2026 21:03:30 GMT"),
                                    page: nil, at: now0.addingTimeInterval(3600))
        XCTAssertEqual(earlier.edition.articles[0].publishedAt, "2026-10-11T21:04:04Z", "a real (flag=false) date is not rewritten")
        XCTAssertEqual(earlier.stats.perSource[0].datesCorrected, 0)
    }

    func testTheEstimatedFlagIsAdditiveOnTheWire() throws {
        // An edition built by an OLD compiler (no field) still decodes; an old decoder ignores the new key.
        let oldJSON = #"{"guid":"g","url":"https://x/y","sourceID":"s","title":"T","publishedAt":"2026-10-11T21:04:04Z","bodyBlocksJSON":"[]"}"#
        XCTAssertNil(try JSONDecoder().decode(EditionArticle.self, from: Data(oldJSON.utf8)).dateIsEstimated)
        struct OldShape: Decodable { let guid: String; let publishedAt: String }   // what a pre-field build decodes
        let flagged = #"{"guid":"g","url":"https://x/y","sourceID":"s","title":"T","publishedAt":"2026-10-11T21:04:04Z","bodyBlocksJSON":"[]","dateIsEstimated":true}"#
        XCTAssertEqual(try JSONDecoder().decode(OldShape.self, from: Data(flagged.utf8)).publishedAt, "2026-10-11T21:04:04Z")
    }
}
