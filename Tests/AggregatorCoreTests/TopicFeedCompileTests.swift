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

    // MARK: - A topic feed supplies the section a main feed's copy lacks

    func testAStoryInBothAMainFeedAndATopicFeedCarriesTheTopicFeedsSection() async throws {
        // The first feed to see a guid still supplies the story (the main feed's copy is the one compiled), but the topic feed
        // that lists it too supplies the section the main feed's copy lacks.
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "shared")])
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "shared"), FeedItemSpec(guid: "biz-only")])
        let stats = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/business", topic: "business", maxPerDay: 10)
        ])])
        let byGUID = hints(try decodeEdition())
        XCTAssertEqual(byGUID.count, 2, "the shared story is compiled once")
        XCTAssertEqual(byGUID["shared"] ?? nil, "business")
        XCTAssertEqual(byGUID["biz-only"] ?? nil, "business")
        let perSource = try XCTUnwrap(stats.perSource.first)
        XCTAssertEqual(perSource.topicLabelsFilled, 1, "counted apart from the stories a topic feed itself supplied")
        XCTAssertEqual(perSource.topicNewArticles, 1)
        XCTAssertEqual(client.requestCount(of: "https://mix.example/news/shared"), 0, "feed-text source: no page is ever fetched")
    }

    func testBetweenTwoTopicFeedsTheFirstListedLabelWins() async throws {
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "shared")])
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "shared")])
        stub("https://mix.example/tech", host: "mix.example", [FeedItemSpec(guid: "shared"), FeedItemSpec(guid: "tech-only")])
        _ = try await compile([source(feeds: [
            feed("https://mix.example/main"),
            feed("https://mix.example/business", topic: "business", maxPerDay: 10),
            feed("https://mix.example/tech", topic: "tech", maxPerDay: 10)
        ])])
        let byGUID = hints(try decodeEdition())
        XCTAssertEqual(byGUID["shared"] ?? nil, "business", "only a MISSING label is filled")
        XCTAssertEqual(byGUID["tech-only"] ?? nil, "tech")
    }

    func testAMainFeedStoryASportsFeedListsWithABettingHeadlineStaysPlainNews() async throws {
        stub("https://mix.example/main", host: "mix.example", [
            FeedItemSpec(guid: "game", title: "Bears hold on to beat the Packers"),
            FeedItemSpec(guid: "bet", title: "Week 7 NFL expert picks and odds")
        ])
        stub("https://mix.example/sport", host: "mix.example", [
            FeedItemSpec(guid: "game", title: "Bears hold on to beat the Packers"),
            FeedItemSpec(guid: "bet", title: "Week 7 NFL expert picks and odds")
        ])
        let stats = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/sport", topic: "sports", maxPerDay: 10)
        ])])
        let byGUID = hints(try decodeEdition())
        XCTAssertEqual(byGUID.count, 2, "the betting story is still compiled: the main feed carried it")
        XCTAssertEqual(byGUID["game"] ?? nil, "sports")
        XCTAssertNil(byGUID["bet"] ?? nil, "a betting headline in a sports feed never labels a story")
        XCTAssertEqual(stats.perSource.first?.topicLabelsFilled, 1)
    }

    func testAnOutOfTopicLabelDoesNotSpendTheTopicFeedsCap() async throws {
        // Three of the business feed's four stories were already taken by the main feed. The label-only ones fetch nothing,
        // so they do not use up the feed's cap of two: both of its own stories are still taken.
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "a"), FeedItemSpec(guid: "b"), FeedItemSpec(guid: "c")])
        stub("https://mix.example/business", host: "mix.example", [
            FeedItemSpec(guid: "a"), FeedItemSpec(guid: "b"), FeedItemSpec(guid: "c"),
            FeedItemSpec(guid: "biz-1"), FeedItemSpec(guid: "biz-2"), FeedItemSpec(guid: "biz-3")
        ])
        let stats = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/business", topic: "business", maxPerDay: 2)
        ])])
        let byGUID = hints(try decodeEdition())
        XCTAssertEqual(Set(byGUID.keys), ["a", "b", "c", "biz-1", "biz-2"], "biz-3 is past the cap of two; the label-only three are not")
        for guid in byGUID.keys { XCTAssertEqual(byGUID[guid] ?? nil, "business", guid) }
        let perSource = try XCTUnwrap(stats.perSource.first)
        XCTAssertEqual(perSource.topicFeedsCapped, 1)
        XCTAssertEqual(perSource.topicNewArticles, 2)
        XCTAssertEqual(perSource.topicLabelsFilled, 3)
    }

    func testALabelNeverCostsAStoryTheTopicFeedsStricterRulesWouldReject() async throws {
        // NPR's topic feeds need 150 words; its main feed does not. The main feed took "short" (102 words), and the business feed
        // lists it too. With the label it would fail the 150-word floor; without it, it passes. It must ship, unlabeled, and
        // nothing is negative-cached. "long" (170 words) passes with the label and keeps it.
        stub("https://npr.example/main", host: "npr.example", [
            FeedItemSpec(guid: "short", paragraphs: 3), FeedItemSpec(guid: "long", paragraphs: 5)
        ])
        stub("https://npr.example/business", host: "npr.example", [
            FeedItemSpec(guid: "short", paragraphs: 3), FeedItemSpec(guid: "long", paragraphs: 5)
        ])
        let stats = try await compile([source(id: "npr", feeds: [
            feed("https://npr.example/main"), feed("https://npr.example/business", topic: "business", maxPerDay: 10)
        ])])
        let byGUID = hints(try decodeEdition())
        XCTAssertEqual(Set(byGUID.keys), ["short", "long"])
        XCTAssertNil(byGUID["short"] ?? nil, "compiled as plain main news")
        XCTAssertEqual(byGUID["long"] ?? nil, "business")
        let perSource = try XCTUnwrap(stats.perSource.first)
        XCTAssertEqual(perSource.gateRejected, 0)
        XCTAssertEqual(perSource.topicLabelsFilled, 1, "only the story that kept its label")
        XCTAssertTrue(CompilerState.load(from: stateURL).rejectedURLs.isEmpty, "no rejection is recorded for a story that shipped")
    }

    func testAStoryThatFailsTheGateWithOrWithoutTheLabelIsRejectedOnceAsBefore() async throws {
        // One paragraph: fails the base gate (>= 3 paragraphs) whatever feed it came through.
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "thin", paragraphs: 1), FeedItemSpec(guid: "fine")])
        stub("https://mix.example/business", host: "mix.example", [FeedItemSpec(guid: "thin", paragraphs: 1)])
        let stats = try await compile([source(feeds: [
            feed("https://mix.example/main"), feed("https://mix.example/business", topic: "business", maxPerDay: 10)
        ])])
        XCTAssertEqual(Set(hints(try decodeEdition()).keys), ["fine"])
        let perSource = try XCTUnwrap(stats.perSource.first)
        XCTAssertEqual(perSource.gateRejected, 1)
        XCTAssertEqual(CompilerState.load(from: stateURL).rejectedURLs.count, 1)
    }

    // MARK: - A feed that answers with nothing is reported, and not remembered

    private func feedErrors(_ stats: RunStats) -> Int { stats.perSource.first?.feedErrors ?? -1 }

    func testAFeedThatAnswersWithAnEmptyChannelIsCountedLoggedAndNotRemembered() async throws {
        client.stubs["https://mix.example/empty"] = .init(
            data: Data(#"<?xml version="1.0"?><rss version="2.0"><channel><title>x</title></channel></rss>"#.utf8),
            etag: "\"empty-1\"", lastModified: "Wed, 05 Aug 2026 11:00:00 GMT")
        stub("https://mix.example/main", host: "mix.example", [FeedItemSpec(guid: "main-1")], etag: "\"main-1\"")
        let errorsBefore = DiagnosticsLog.shared.errorCount
        let stats = try await compile([source(feeds: [feed("https://mix.example/empty"), feed("https://mix.example/main")])])

        XCTAssertEqual(feedErrors(stats), 1)
        XCTAssertEqual(DiagnosticsLog.shared.errorCount - errorsBefore, 1, "one error-level log line")
        XCTAssertEqual(Set(hints(try decodeEdition()).keys), ["main-1"], "the source's other feed still compiles")
        let state = CompilerState.load(from: stateURL)
        XCTAssertNil(state.feedConditionals["https://mix.example/empty"], "an empty answer stores no ETag or Last-Modified")
        XCTAssertEqual(state.feedConditionals["https://mix.example/main"]?.etag, "\"main-1\"", "a feed with items still does")

        // The next run asks for the empty feed WITHOUT a conditional, so a server that would now answer properly is believed.
        client.notModifiedURLs = ["https://mix.example/empty"]
        stub("https://mix.example/empty", host: "mix.example", [FeedItemSpec(guid: "empty-now-full")], etag: "\"empty-2\"")
        let second = try await compile([source(feeds: [feed("https://mix.example/empty"), feed("https://mix.example/main")])])
        XCTAssertEqual(feedErrors(second), 0)
        XCTAssertEqual(second.perSource.first?.feedsNotModified, 0, "no conditional was sent, so no 304")
        XCTAssertTrue(hints(try decodeEdition()).keys.contains("empty-now-full"))
    }

    func testAnHTMLPageAnsweredInPlaceOfAFeedIsCountedLoggedAndNotRemembered() async throws {
        // Well-formed enough to parse as XML, so it reaches the feed parser as "zero items" rather than as an error.
        client.stubs["https://mix.example/wall"] = .init(
            data: Data("<html><head><title>Just a moment</title></head><body><p>Enable JavaScript and cookies to continue</p></body></html>".utf8),
            etag: "\"wall-1\"", lastModified: nil)
        let errorsBefore = DiagnosticsLog.shared.errorCount
        let stats = try await compile([source(feeds: [feed("https://mix.example/wall")])])
        XCTAssertEqual(feedErrors(stats), 1)
        XCTAssertEqual(DiagnosticsLog.shared.errorCount - errorsBefore, 1)
        XCTAssertNil(CompilerState.load(from: stateURL).feedConditionals["https://mix.example/wall"])
    }

    func testAFeedThatFailsToParseNoLongerStoresItsETag() async throws {
        // An HTML document with an unclosed tag: the XML parser refuses it.
        client.stubs["https://mix.example/broken"] = .init(
            data: Data("<!DOCTYPE html><html><body><br><p>Access denied</body></html>".utf8), etag: "\"broken-1\"", lastModified: nil)
        let stats = try await compile([source(feeds: [feed("https://mix.example/broken")])])
        XCTAssertEqual(feedErrors(stats), 1)
        XCTAssertNil(CompilerState.load(from: stateURL).feedConditionals["https://mix.example/broken"],
                     "a stored ETag would make the next run's answer a 304 and the feed would never be read again")
    }

    func testTheEmptyAnswerPreviewIsOnePrintableLineOfAtMostTwoHundredCharacters() {
        let messy = "  <html>\n\t<head>\u{0}<title>Just   a\u{7}  moment</title>\r\n</head>\u{200B}</html>  "
        XCTAssertEqual(EditionCompiler.feedBodyPreview(Data(messy.utf8)), "<html> <head><title>Just a moment</title> </head></html>")
        XCTAssertEqual(EditionCompiler.feedBodyPreview(Data()), "")
        XCTAssertEqual(EditionCompiler.feedBodyPreview(Data([0xFF, 0xFE, 0x00, 0x41, 0xFF])), "A", "undecodable bytes are dropped")
        let long = String(repeating: "word ", count: 200)
        let preview = EditionCompiler.feedBodyPreview(Data(long.utf8))
        XCTAssertLessThanOrEqual(preview.count, 200)
        XCTAssertGreaterThan(preview.count, 150)
        XCTAssertFalse(preview.contains("  "))
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
