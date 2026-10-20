import XCTest
@testable import AggregatorCore

/// Sections (topic feeds) in the edition compiler: a feed that declares a topic (`FeedEndpoint.topicHint`) tags each article it
/// supplies, the tag travels into the bundle as the optional `topicHint` key, a topic feed has its own per-run cap
/// (`FeedEndpoint.topicMaxPerDay`) that neither spends nor is spent by the source's `maxItemsPerSourcePerRun`, and the bundle stays
/// byte-compatible when no feed declares a topic.
final class TopicFeedCompileTests: XCTestCase {
    private var outDir: URL!
    private var stateURL: URL!
    private var client: FakeHTTPClient!
    /// 2026-08-05T12:00:00Z, as in the other compiler tests.
    private let now = Date(timeIntervalSince1970: 1_785_931_200)

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topic-feed-test-\(UUID().uuidString)")
        outDir = root.appendingPathComponent("out")
        stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        client = FakeHTTPClient()
        DiagnosticsLog.shared.isSilenced = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outDir.deletingLastPathComponent())
        DiagnosticsLog.shared.isSilenced = false
    }

    // MARK: fixtures

    private let sentence = "City officials confirmed the plan on Monday after months of public hearings and detailed negotiations with neighborhood groups across the area, promising further updates as the work proceeds through the fall season and beyond."

    /// `paragraphs` paragraphs of `sentence` (34 words, 228 characters each): 3 clears the gate's floors (102 words), 5 clears the
    /// 150-word floor of topic feeds from NPR (170 words).
    private func body(paragraphs: Int = 3) -> String {
        (0..<paragraphs).map { _ in "<p>\(sentence)</p>" }.joined()
    }

    private func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    private struct FeedItemSpec {
        var guid: String
        var title: String? = nil
        var path: String? = nil
        var paragraphs = 3
        var minutesAgo = 60
    }

    private func feedXML(host: String, items: [FeedItemSpec]) -> String {
        let rendered = items.map { item in
            """
            <item>
              <title>\(item.title ?? "Story \(item.guid)")</title>
              <link>https://\(host)/\(item.path ?? "news/\(item.guid)")</link>
              <guid>\(item.guid)</guid>
              <pubDate>\(rfc822(now.addingTimeInterval(-Double(item.minutesAgo) * 60)))</pubDate>
              <content:encoded><![CDATA[\(body(paragraphs: item.paragraphs))]]></content:encoded>
            </item>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>\(host)</title>
        \(rendered)
        </channel></rss>
        """
    }

    private func stub(_ urlString: String, host: String, _ items: [FeedItemSpec], etag: String? = nil) {
        client.stubs[urlString] = .init(data: Data(feedXML(host: host, items: items).utf8), etag: etag, lastModified: nil)
    }

    private func source(id: String = "mix", feeds: [FeedEndpoint]) -> SourceConfig {
        SourceConfig(id: id, name: id, feeds: feeds, strategy: .feedFullText, weight: 1.0, bodySelector: nil,
                     excludeURLPatterns: [], maxPerDay: 40)
    }

    private func feed(_ urlString: String, topic: String? = nil, maxPerDay: Int? = nil) -> FeedEndpoint {
        FeedEndpoint(url: URL(string: urlString)!, defaultCategory: .us, topicHint: topic, maxPerDay: maxPerDay)
    }

    private func compile(_ catalog: [SourceConfig], maxItemsPerSourcePerRun: Int = 60) async throws -> RunStats {
        var configuration = CompilerConfiguration(baseURL: "https://pages.example/edition/", outDirectory: outDir,
                                                  stateFileURL: stateURL, now: { self.now })
        configuration.maxItemsPerSourcePerRun = maxItemsPerSourcePerRun
        return try await EditionCompiler(catalog: catalog, client: client, resizer: FakeResizer(), configuration: configuration).run()
    }

    private func editionJSON() throws -> Data {
        let result = try ProcessRunner.run(["gunzip", "-c", outDir.appendingPathComponent("edition.json.gz").path])
        XCTAssertEqual(result.status, 0, result.stderrText)
        return result.stdout
    }

    private func decodeEdition() throws -> Edition { try JSONDecoder().decode(Edition.self, from: editionJSON()) }

    private func hints(_ edition: Edition) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: edition.articles.map { ($0.guid, $0.topicHint) })
    }

    // MARK: - The hint travels into the bundle

    func testTopicFeedArticlesCarryTheirHintAndMainFeedArticlesCarryNone() async throws {
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "main-1")])
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "biz-1")])
        stub("https://mix.example/sport", host: "mix.example", [FeedItemSpec(guid: "sport-1")])
        _ = try await compile([source(feeds: [
            feed("https://mix.example/main"),
            feed("https://mix.example/business", topic: "business", maxPerDay: 10),
            feed("https://mix.example/sport", topic: "sports", maxPerDay: 10)
        ])])

        let edition = try decodeEdition()
        let byGUID = hints(edition)
        XCTAssertEqual(byGUID.count, 3)
        XCTAssertEqual(byGUID["biz-1"] ?? nil, "business")
        XCTAssertEqual(byGUID["sport-1"] ?? nil, "sports")
        XCTAssertNil(byGUID["main-1"] ?? nil, "an article from a main feed carries no hint")

        // The key is ABSENT (not null) for the main article, so older readers see exactly the old shape.
        let raw = try JSONSerialization.jsonObject(with: editionJSON()) as? [String: Any]
        let articles = try XCTUnwrap(raw?["articles"] as? [[String: Any]])
        let main = try XCTUnwrap(articles.first { $0["guid"] as? String == "main-1" })
        XCTAssertNil(main["topicHint"])
        XCTAssertFalse(main.keys.contains("topicHint"))
        let biz = try XCTUnwrap(articles.first { $0["guid"] as? String == "biz-1" })
        XCTAssertEqual(biz["topicHint"] as? String, "business")
    }

    func testABundleWithNoTopicFeedIsExactlyTheOldShape() async throws {
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "main-1"), FeedItemSpec(guid: "main-2")])
        _ = try await compile([source(feeds: [feed("https://mix.example/main")])])
        let text = try XCTUnwrap(String(data: editionJSON(), encoding: .utf8))
        XCTAssertFalse(text.contains("topicHint"), "no feed declares a topic, so the key never appears")
        XCTAssertEqual(try decodeEdition().articles.count, 2)
    }

    func testTheHintIsKeptInStateSoARetainedArticleKeepsIt() async throws {
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "biz-1")])
        let catalog = [source(feeds: [feed("https://mix.example/business", topic: "business", maxPerDay: 10)])]
        _ = try await compile(catalog)
        // Second run: the feed now lists nothing new; the article is retained from state and still carries its hint.
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "biz-1")])
        let stats = try await compile(catalog)
        XCTAssertEqual(stats.newArticles, 0)
        XCTAssertEqual(stats.retainedArticles, 1)
        XCTAssertEqual(hints(try decodeEdition())["biz-1"] ?? nil, "business")
    }

    func testAnOldBundleAndAnOldStateFileStillDecode() throws {
        let oldBundle = """
        {"schemaVersion":1,"generatedAt":"2026-08-05T12:00:00Z","windowHours":48,"articles":[
        {"guid":"g","url":"https://a.example/x","sourceID":"mix","title":"T","publishedAt":"2026-08-05T11:00:00Z","bodyBlocksJSON":"[]"}]}
        """
        let edition = try JSONDecoder().decode(Edition.self, from: Data(oldBundle.utf8))
        XCTAssertNil(edition.articles[0].topicHint)

        let oldState = """
        {"schemaVersion":1,"feedConditionals":{},"rejectedURLs":{},"articles":[
        {"guid":"g","url":"https://a.example/x","sourceID":"mix","title":"T","publishedAt":"2026-08-05T11:00:00Z","bodyBlocksJSON":"[]"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(CompilerState.self, from: Data(oldState.utf8))
        XCTAssertNil(state.articles[0].topicHint)
    }

    // MARK: - Caps

    func testATopicFeedHasItsOwnPerRunCap_andTheMainCapStillBindsTheMainFeed() async throws {
        stub("https://mix.example/main", host: "mix.example", (0..<5).map { FeedItemSpec(guid: "main-\($0)", minutesAgo: 10 + $0) })
        stub("https://mix.example/business", host: "mix.example", (0..<6).map { FeedItemSpec(guid: "biz-\($0)", minutesAgo: 10 + $0) })
        let stats = try await compile([source(feeds: [
            feed("https://mix.example/main"),
            feed("https://mix.example/business", topic: "business", maxPerDay: 2)
        ])], maxItemsPerSourcePerRun: 3)

        let perSource = try XCTUnwrap(stats.perSource.first)
        XCTAssertTrue(perSource.hitItemCap, "the MAIN feed hit the source cap (5 items, cap 3)")
        XCTAssertEqual(perSource.topicFeedsCapped, 1, "the topic feed hit its own cap of 2")
        let byGUID = hints(try decodeEdition())
        XCTAssertEqual(byGUID.keys.filter { $0.hasPrefix("main-") }.count, 3, "main feed: the source cap")
        XCTAssertEqual(byGUID.keys.filter { $0.hasPrefix("biz-") }.count, 2, "topic feed: its own cap, newest first")
        XCTAssertNotNil(byGUID["biz-0"])
        XCTAssertNotNil(byGUID["biz-1"])
        XCTAssertNil(byGUID["biz-2"])
        XCTAssertEqual(perSource.topicNewArticles, 2)
    }

    func testAnExhaustedMainCapDoesNotStopTheTopicFeedsThatFollow() async throws {
        // The source's main feed alone fills the cap; the topic feed is listed AFTER it and used to be skipped with the rest.
        stub("https://mix.example/main", host: "mix.example", (0..<8).map { FeedItemSpec(guid: "main-\($0)") })
        stub("https://mix.example/sport", host: "mix.example", (0..<4).map { FeedItemSpec(guid: "sport-\($0)") })
        _ = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/sport", topic: "sports", maxPerDay: 10)
        ])], maxItemsPerSourcePerRun: 3)
        let guids = Set(hints(try decodeEdition()).keys)
        XCTAssertEqual(guids.filter { $0.hasPrefix("main-") }.count, 3)
        XCTAssertEqual(guids.filter { $0.hasPrefix("sport-") }.count, 4, "all four: the topic feed has its own budget")
    }

    func testABusyTopicFeedNeverCrowdsOutTheMainFeedEither() async throws {
        stub("https://mix.example/main", host: "mix.example", (0..<4).map { FeedItemSpec(guid: "main-\($0)") })
        stub("https://mix.example/business", host: "mix.example", (0..<30).map { FeedItemSpec(guid: "biz-\($0)") })
        let stats = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/business", topic: "business", maxPerDay: 10)
        ])], maxItemsPerSourcePerRun: 4)
        let perSource = try XCTUnwrap(stats.perSource.first)
        XCTAssertFalse(perSource.hitItemCap, "four main items fit a cap of four: topic items do not count against it")
        let guids = Set(hints(try decodeEdition()).keys)
        XCTAssertEqual(guids.filter { $0.hasPrefix("main-") }.count, 4)
        XCTAssertEqual(guids.filter { $0.hasPrefix("biz-") }.count, 10)
    }

    func testATopicFeedThatNamesNoMaxPerDayCapsAtTen() async throws {
        stub("https://mix.example/business", host: "mix.example", (0..<14).map { FeedItemSpec(guid: "biz-\($0)") })
        _ = try await compile([source(feeds: [feed("https://mix.example/business", topic: "business")])])
        XCTAssertEqual(try decodeEdition().articles.count, FeedEndpoint.defaultTopicFeedMaxPerDay)
        XCTAssertEqual(FeedEndpoint.defaultTopicFeedMaxPerDay, 10)
    }

    func testACappedTopicFeedWithholdsOnlyItsOwnConditional_soItsRemainderDrainsNextRun() async throws {
        stub("https://mix.example/business", host: "mix.example", (0..<5).map { FeedItemSpec(guid: "biz-\($0)") }, etag: "\"biz-1\"")
        stub("https://mix.example/tech", host: "mix.example", [FeedItemSpec(guid: "tech-0")], etag: "\"tech-1\"")
        let catalog = [source(feeds: [
            feed("https://mix.example/business", topic: "business", maxPerDay: 2),
            feed("https://mix.example/tech", topic: "tech", maxPerDay: 10)
        ])]
        _ = try await compile(catalog)
        let state = CompilerState.load(from: stateURL)
        XCTAssertNil(state.feedConditionals["https://mix.example/business"], "the capped feed is re-fetched in full next run")
        XCTAssertEqual(state.feedConditionals["https://mix.example/tech"]?.etag, "\"tech-1\"", "its sibling stays cheap")

        // The next run drains the next two of the capped feed (the first two are known and skipped).
        _ = try await compile(catalog)
        let guids = Set(hints(try decodeEdition()).keys)
        XCTAssertEqual(guids.filter { $0.hasPrefix("biz-") }.count, 4)
    }

    // MARK: - Quality rules in the survey and the gate

    func testPagesTheGateWouldRejectByAddressOrBettingHeadlineAreSkippedBeforeAnyFetch() async throws {
        stub("https://mix.example/sport", host: "mix.example", [
            FeedItemSpec(guid: "ok", title: "Bears hold on to beat the Packers"),
            FeedItemSpec(guid: "gallery", title: "Photos from the game", path: "sport/gallery/2026/oct/05/photos"),
            FeedItemSpec(guid: "live", title: "Bears v Packers: as it happened", path: "sport/live/2026/oct/05/bears"),
            FeedItemSpec(guid: "odds", title: "Week 7 NFL expert picks and odds"),
            FeedItemSpec(guid: "fantasy", title: "Fantasy football waiver wire: who to add"),
            FeedItemSpec(guid: "promo", title: "Best promo code for Sunday's slate")
        ])
        let stats = try await compile([source(feeds: [feed("https://mix.example/sport", topic: "sports", maxPerDay: 10)])])
        XCTAssertEqual(Set(hints(try decodeEdition()).keys), ["ok"])
        XCTAssertEqual(stats.perSource.first?.eligibleItems, 1, "the rest never became eligible, so no page would be fetched")
        XCTAssertEqual(stats.perSource.first?.gateRejected, 0)
    }

    func testTheBettingHeadlineRuleAppliesToSportsFeedsOnly() async throws {
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "odds", title: "The odds of a soft landing improve")])
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "main-odds", title: "Why the odds favor the incumbent")])
        _ = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/business", topic: "business", maxPerDay: 10)
        ])])
        XCTAssertEqual(Set(hints(try decodeEdition()).keys), ["odds", "main-odds"])
    }

    func testNPRTopicFeedsNeedA150WordBodyButNPRMainFeedsDoNot() async throws {
        // 3 paragraphs = 102 words: clears the base gate (>= 600 characters) but not NPR's 150-word topic-feed floor.
        stub("https://npr.example/main", host: "npr.example", [FeedItemSpec(guid: "main-short", paragraphs: 3)])
        stub("https://npr.example/business", host: "npr.example", [
            FeedItemSpec(guid: "biz-short", paragraphs: 3), FeedItemSpec(guid: "biz-long", paragraphs: 5)
        ])
        let stats = try await compile([source(id: "npr", feeds: [
            feed("https://npr.example/main"), feed("https://npr.example/business", topic: "business", maxPerDay: 10)
        ])])
        XCTAssertEqual(Set(hints(try decodeEdition()).keys), ["main-short", "biz-long"])
        XCTAssertEqual(stats.perSource.first?.gateRejected, 1)
    }

    func testTheSameShortBodyFromAnotherOutletsTopicFeedPasses() async throws {
        stub("https://other.example/business", host: "other.example", [FeedItemSpec(guid: "biz-short", paragraphs: 3)])
        _ = try await compile([source(id: "other", feeds: [feed("https://other.example/business", topic: "business", maxPerDay: 10)])])
        XCTAssertEqual(Set(hints(try decodeEdition()).keys), ["biz-short"])
    }

    func testAStoryInBothAMainFeedAndATopicFeedKeepsTheFirstFeedsView() async throws {
        // The first feed to see a guid wins (as it always has): the main feed's copy has no hint.
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "shared")])
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "shared"), FeedItemSpec(guid: "biz-only")])
        _ = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/business", topic: "business", maxPerDay: 10)
        ])])
        let byGUID = hints(try decodeEdition())
        XCTAssertEqual(byGUID.count, 2)
        XCTAssertNil(byGUID["shared"] ?? nil)
        XCTAssertEqual(byGUID["biz-only"] ?? nil, "business")
    }

    // MARK: - The real catalog

    func testEveryTopicFeedInTheRealCatalogHasAHintAndATenAStoryCap() {
        var topicFeeds = 0
        for source in SourceCatalog.all {
            for feed in source.feeds {
                if feed.isTopicFeed {
                    topicFeeds += 1
                    XCTAssertEqual(feed.topicMaxPerDay, 10, "\(source.id) \(feed.url)")
                } else {
                    XCTAssertNil(feed.maxPerDay, "\(source.id): a main feed has no per-feed budget")
                }
            }
        }
        XCTAssertEqual(topicFeeds, 67)
    }
}
