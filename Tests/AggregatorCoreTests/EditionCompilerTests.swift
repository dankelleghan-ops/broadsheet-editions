import XCTest
@testable import AggregatorCore

// MARK: - Fakes

final class FakeHTTPClient: AggregatorHTTPClient, @unchecked Sendable {
    struct Stub {
        var data: Data
        var etag: String?
        var lastModified: String?
    }

    private let lock = NSLock()
    var stubs: [String: Stub] = [:]
    /// URLs that answer 304 whenever the request carries any conditional.
    var notModifiedURLs: Set<String> = []
    var failURLs: Set<String> = []
    private(set) var requestedURLs: [String] = []
    /// Last maxBytes cap passed for each URL (finding 3e) -- lets tests pin which cap each
    /// call site carries.
    private(set) var requestedMaxBytes: [String: Int] = [:]
    /// URLs whose responses BLOCK until `openGate()` -- lets a test observe mid-run state
    /// checkpoints (finding 3a) deterministically.
    var gatedURLs: Set<String> = []
    private var gateOpen = false
    /// Called (outside the lock) for every request, after gating -- lets a test advance a
    /// fake clock at a precise fetch (finding 3b).
    var onRequest: ((String) -> Void)?

    func openGate() {
        lock.lock()
        gateOpen = true
        lock.unlock()
    }

    func get(_ url: URL, conditional: FeedConditional?, maxBytes: Int?) async throws -> FetchResponse {
        while true {
            lock.lock()
            let blocked = gatedURLs.contains(url.absoluteString) && !gateOpen
            lock.unlock()
            if !blocked { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        lock.lock()
        requestedURLs.append(url.absoluteString)
        if let maxBytes { requestedMaxBytes[url.absoluteString] = maxBytes }
        let stub = stubs[url.absoluteString]
        let fails = failURLs.contains(url.absoluteString)
        let notModified = notModifiedURLs.contains(url.absoluteString)
        let hook = onRequest
        lock.unlock()
        hook?(url.absoluteString)

        if fails { throw FetchError.httpStatus(500) }
        if notModified, let conditional, !conditional.isEmpty {
            return FetchResponse(statusCode: 304, data: Data(),
                                 etag: conditional.etag, lastModified: conditional.lastModified)
        }
        guard let stub else { throw FetchError.httpStatus(404) }
        // Enforce the cap the way the real Fetcher does (finding 3e).
        if SizeCap.accumulatedExceeds(limit: maxBytes, count: stub.data.count) {
            throw FetchError.responseTooLarge(limit: maxBytes ?? 0)
        }
        return FetchResponse(statusCode: 200, data: stub.data,
                             etag: stub.etag, lastModified: stub.lastModified)
    }

    func requestCount(of urlString: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestedURLs.filter { $0 == urlString }.count
    }
}

/// Deterministic "resize": output = "RESIZED:" + raw bytes, so content-sha naming is testable
/// without a real image tool.
struct FakeResizer: ImageResizing {
    func resize(rawData: Data, outputURL: URL) throws {
        var out = Data("RESIZED:".utf8)
        out.append(rawData)
        try out.write(to: outputURL)
    }
}

// MARK: - Tests

final class EditionCompilerTests: XCTestCase {
    private var outDir: URL!
    private var stateURL: URL!
    private var client: FakeHTTPClient!
    /// Fixed "now" so windowing is deterministic: 2026-08-05T12:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_785_931_200)

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edition-test-\(UUID().uuidString)")
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

    private let longParagraph = "City officials confirmed the plan on Monday after months of public hearings and detailed negotiations with neighborhood groups across the area, promising further updates as the work proceeds through the fall season and beyond."

    private func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    private func goodContentHTML(withImage: Bool) -> String {
        let img = withImage ? "<img src=\"https://img.example/wire-photo.jpg\"/>" : ""
        return "<p>\(longParagraph)</p><p>\(longParagraph)</p>\(img)<p>\(longParagraph)</p>"
    }

    private func wireFeedXML(includeGateFail: Bool = true) -> String {
        let published = rfc822(now.addingTimeInterval(-3600))
        let gateFailItem = includeGateFail ? """
        <item>
          <title>Too Thin To Pass</title>
          <link>https://wire.example/thin</link>
          <guid>wire-thin-1</guid>
          <pubDate>\(published)</pubDate>
          <content:encoded><![CDATA[<p>Short.</p>]]></content:encoded>
        </item>
        """ : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel>
          <title>Wire</title>
          <item>
            <title>Council Approves Lakefront Plan</title>
            <link>https://wire.example/lakefront</link>
            <guid>wire-lakefront-1</guid>
            <pubDate>\(published)</pubDate>
            <content:encoded><![CDATA[\(goodContentHTML(withImage: true))]]></content:encoded>
          </item>
          <item>
            <title>Clip Show</title>
            <link>https://wire.example/video/clip-show</link>
            <guid>wire-video-1</guid>
            <pubDate>\(published)</pubDate>
            <content:encoded><![CDATA[\(goodContentHTML(withImage: false))]]></content:encoded>
          </item>
          <item>
            <title>How to watch the big game tonight</title>
            <link>https://wire.example/promo</link>
            <guid>wire-promo-1</guid>
            <pubDate>\(published)</pubDate>
            <content:encoded><![CDATA[\(goodContentHTML(withImage: false))]]></content:encoded>
          </item>
          <item>
            <title>Ancient History Item</title>
            <link>https://wire.example/old</link>
            <guid>wire-old-1</guid>
            <pubDate>\(rfc822(now.addingTimeInterval(-72 * 3600)))</pubDate>
            <content:encoded><![CDATA[\(goodContentHTML(withImage: false))]]></content:encoded>
          </item>
          \(gateFailItem)
        </channel>
        </rss>
        """
    }

    private func paperFeedXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
        <channel>
          <title>Paper</title>
          <item>
            <title>Bridge Repairs Begin</title>
            <link>https://paper.example/bridge</link>
            <guid>paper-bridge-1</guid>
            <pubDate>\(rfc822(now.addingTimeInterval(-7200)))</pubDate>
          </item>
        </channel>
        </rss>
        """
    }

    private func paperPageHTML() -> String {
        """
        <html><head><meta property="og:image" content="https://img.example/paper-hero.jpg"></head>
        <body><main id="maincontent">
        <p>\(longParagraph)</p><p>\(longParagraph)</p><p>\(longParagraph)</p>
        </main></body></html>
        """
    }

    private func testCatalog() -> [SourceConfig] {
        [
            SourceConfig(id: "wire", name: "Wire", feeds: [
                FeedEndpoint(url: URL(string: "https://wire.example/feed")!, defaultCategory: .us)
            ], strategy: .feedFullText, weight: 1.0, bodySelector: nil,
               excludeURLPatterns: ["/video/"], maxPerDay: 40,
               excludeTitlePrefixes: ["how to watch"]),
            SourceConfig(id: "paper", name: "Paper", feeds: [
                FeedEndpoint(url: URL(string: "https://paper.example/feed")!, defaultCategory: .us)
            ], strategy: .pageExtract, weight: 1.0, bodySelector: "#maincontent",
               excludeURLPatterns: [], maxPerDay: 40)
        ]
    }

    private func stubAll() {
        client.stubs["https://wire.example/feed"] = .init(data: Data(wireFeedXML().utf8), etag: "W/\"wire-1\"", lastModified: nil)
        client.stubs["https://paper.example/feed"] = .init(data: Data(paperFeedXML().utf8), etag: nil, lastModified: "Tue, 04 Aug 2026 10:00:00 GMT")
        client.stubs["https://paper.example/bridge"] = .init(data: Data(paperPageHTML().utf8), etag: nil, lastModified: nil)
        client.stubs["https://img.example/wire-photo.jpg"] = .init(data: Data("WIREPHOTOBYTES".utf8), etag: nil, lastModified: nil)
        client.stubs["https://img.example/paper-hero.jpg"] = .init(data: Data("PAPERHEROBYTES".utf8), etag: nil, lastModified: nil)
    }

    private func makeCompiler(catalog: [SourceConfig]? = nil,
                              configure: (inout CompilerConfiguration) -> Void = { _ in }) -> EditionCompiler {
        var configuration = CompilerConfiguration(
            baseURL: "https://pages.example/edition/",
            outDirectory: outDir,
            stateFileURL: stateURL,
            now: { self.now }
        )
        configure(&configuration)
        return EditionCompiler(
            catalog: catalog ?? testCatalog(),
            client: client,
            resizer: FakeResizer(),
            configuration: configuration
        )
    }

    private func decodeEdition() throws -> Edition {
        let gzPath = outDir.appendingPathComponent("edition.json.gz").path
        let result = try ProcessRunner.run(["gunzip", "-c", gzPath])
        XCTAssertEqual(result.status, 0, result.stderrText)
        return try JSONDecoder().decode(Edition.self, from: result.stdout)
    }

    private func expectedSHA16(forRaw raw: String) -> String {
        var resized = Data("RESIZED:".utf8)
        resized.append(Data(raw.utf8))
        return SHA256.hexDigest16(resized)
    }

    // MARK: - First run

    func testFirstRunCompilesGatePassingArticlesOnly() async throws {
        stubAll()
        let stats = try await makeCompiler().run()

        XCTAssertEqual(stats.newArticles, 2)
        XCTAssertEqual(stats.retainedArticles, 0)
        XCTAssertEqual(stats.totalArticles, 2)
        let wireStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "wire" })
        XCTAssertEqual(wireStats.newArticles, 1)
        XCTAssertEqual(wireStats.gateRejected, 1) // the thin item
        // excluded URL pattern + excluded title prefix + out-of-window item never became
        // eligible at all
        XCTAssertEqual(wireStats.eligibleItems, 2) // good + thin

        let edition = try decodeEdition()
        XCTAssertEqual(edition.schemaVersion, 1)
        XCTAssertEqual(edition.windowHours, 48)
        XCTAssertEqual(edition.generatedAt, EditionDates.string(from: now))
        XCTAssertEqual(edition.articles.count, 2)
        // Sorted newest first: paper (-2h) is older than wire (-1h).
        XCTAssertEqual(edition.articles.map(\.guid), ["wire-lakefront-1", "paper-bridge-1"])
        XCTAssertEqual(edition.articles.map(\.sourceID), ["wire", "paper"])

        let wireArticle = edition.articles[0]
        XCTAssertEqual(wireArticle.url, "https://wire.example/lakefront")
        XCTAssertEqual(wireArticle.title, "Council Approves Lakefront Plan")
        XCTAssertEqual(wireArticle.publishedAt, EditionDates.string(from: now.addingTimeInterval(-3600)))

        // bodyBlocksJSON matches the app's own encoder shape for those blocks (parsed-JSON
        // equality -- default JSONEncoder key order is not stable across instances).
        let blocks = try JSONDecoder().decode([BodyBlock].self, from: Data(wireArticle.bodyBlocksJSON.utf8))
        XCTAssertEqual(blocks.filter { $0.kind == .paragraph }.count, 3)
        XCTAssertEqual(blocks.filter { $0.kind == .image }.count, 1)
        let reEncoded = try JSONEncoder().encode(blocks)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(wireArticle.bodyBlocksJSON.utf8)) as? NSArray,
                       try JSONSerialization.jsonObject(with: reEncoded) as? NSArray)

        // Content-sha image naming + absolute base URL (trailing slash normalized away).
        let wireSHA = expectedSHA16(forRaw: "WIREPHOTOBYTES")
        XCTAssertEqual(wireArticle.topImageURL, "https://pages.example/edition/images/\(wireSHA).jpg")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outDir.appendingPathComponent("images/\(wireSHA).jpg").path))
        let paperSHA = expectedSHA16(forRaw: "PAPERHEROBYTES")
        XCTAssertEqual(edition.articles[1].topImageURL, "https://pages.example/edition/images/\(paperSHA).jpg")

        // Gate rejection negative-cached in state.
        let state = CompilerState.load(from: stateURL)
        XCTAssertEqual(state.articles.count, 2)
        XCTAssertTrue(state.isRejected(URL(string: "https://wire.example/thin")!))
        XCTAssertNotNil(state.feedConditionals["https://wire.example/feed"]?.etag)
    }

    // MARK: - Steady state

    func testSecondRunRetainsVia304AndSkipsKnownAndRejected() async throws {
        stubAll()
        _ = try await makeCompiler().run()

        // Run 2: paper's feed 304s; wire's feed serves fresh (same content), so its good item
        // must be skipped as already-known and its thin item as previously-rejected.
        let client2 = FakeHTTPClient()
        client2.stubs = client.stubs
        client2.notModifiedURLs = ["https://paper.example/feed"]
        client = client2
        let stats = try await makeCompiler().run()

        XCTAssertEqual(stats.newArticles, 0)
        XCTAssertEqual(stats.retainedArticles, 2)
        XCTAssertEqual(stats.totalArticles, 2)
        let paperStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "paper" })
        XCTAssertEqual(paperStats.feedsNotModified, 1)
        let wireStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "wire" })
        XCTAssertEqual(wireStats.skippedPreviouslyRejected, 1)

        // No article page or image was re-fetched.
        XCTAssertEqual(client2.requestCount(of: "https://paper.example/bridge"), 0)
        XCTAssertEqual(client2.requestCount(of: "https://img.example/wire-photo.jpg"), 0)

        // The edition still carries both articles, and the retained images survived pruning.
        let edition = try decodeEdition()
        XCTAssertEqual(edition.articles.map(\.guid), ["wire-lakefront-1", "paper-bridge-1"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outDir.appendingPathComponent("images/\(expectedSHA16(forRaw: "WIREPHOTOBYTES")).jpg").path))
    }

    // MARK: - Pruning

    func testUnreferencedImagesArePruned() async throws {
        stubAll()
        let strayURL = outDir.appendingPathComponent("images/deadbeefdeadbeef.jpg")
        try FileManager.default.createDirectory(at: outDir.appendingPathComponent("images"),
                                                withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: strayURL)

        let stats = try await makeCompiler().run()
        XCTAssertEqual(stats.prunedImageCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayURL.path))
        // Referenced images survive.
        XCTAssertEqual(stats.imageCount, 2)
    }

    // MARK: - Failure tolerance

    func testHeroImageFailureShipsArticleTextFirst() async throws {
        stubAll()
        client.failURLs = ["https://img.example/paper-hero.jpg"]
        let stats = try await makeCompiler().run()

        XCTAssertEqual(stats.newArticles, 2)
        let paperStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "paper" })
        XCTAssertEqual(paperStats.imageFailures, 1)
        let edition = try decodeEdition()
        let paper = try XCTUnwrap(edition.articles.first { $0.sourceID == "paper" })
        XCTAssertNil(paper.topImageURL, "article ships text-first when its hero fails")
    }

    func testFeedFailureDoesNotSinkTheRun() async throws {
        stubAll()
        client.failURLs = ["https://wire.example/feed"]
        let stats = try await makeCompiler().run()
        XCTAssertEqual(stats.newArticles, 1) // paper still compiles
        let wireStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "wire" })
        XCTAssertEqual(wireStats.feedErrors, 1)
    }

    // MARK: - Per-source checkpoints (finding 3a)

    /// A killed run must resume from the last COMPLETED source, not restart from nothing:
    /// state saves after each source finishes, and a source's feed conditionals commit only
    /// together with its articles (a checkpoint carrying a fresher conditional than the
    /// articles it compiled would make the next run 304 straight past the lost items).
    func testStateCheckpointsAfterEachSourceCompletes() async throws {
        stubAll()
        client.gatedURLs = ["https://paper.example/bridge"]
        let gatedClient = client!
        addTeardownBlock { gatedClient.openGate() }
        let compiler = makeCompiler()
        let runHandle = Task { try await compiler.run() }

        // While paper is still blocked mid-download, wire's completed source must already be
        // on disk: its article, its gate rejection, and its feed conditional.
        var checkpoint: CompilerState?
        for _ in 0..<1000 {
            let state = CompilerState.load(from: stateURL)
            if state.articles.contains(where: { $0.guid == "wire-lakefront-1" }) {
                checkpoint = state
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let midRun = try XCTUnwrap(checkpoint, "wire's completed source must be saved before the run ends")
        XCTAssertTrue(midRun.isRejected(URL(string: "https://wire.example/thin")!))
        XCTAssertNotNil(midRun.feedConditionals["https://wire.example/feed"])
        // paper has NOT completed: neither its article nor its conditional may be saved yet.
        XCTAssertFalse(midRun.articles.contains { $0.guid == "paper-bridge-1" })
        XCTAssertNil(midRun.feedConditionals["https://paper.example/feed"])

        client.openGate()
        let stats = try await runHandle.value
        XCTAssertEqual(stats.newArticles, 2)
        let final = CompilerState.load(from: stateURL)
        XCTAssertTrue(final.articles.contains { $0.guid == "paper-bridge-1" })
        XCTAssertNotNil(final.feedConditionals["https://paper.example/feed"])
    }

    // MARK: - Per-source item cap (finding 3c)

    private func floodFeedXML(count: Int) -> String {
        let published = rfc822(now.addingTimeInterval(-3600))
        let items = (1...count).map { index in
            """
            <item>
              <title>Flood Item \(index)</title>
              <link>https://wire.example/flood-\(index)</link>
              <guid>wire-flood-\(index)</guid>
              <pubDate>\(published)</pubDate>
              <content:encoded><![CDATA[\(goodContentHTML(withImage: false))]]></content:encoded>
            </item>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel>
          <title>Wire</title>
          \(items)
        </channel>
        </rss>
        """
    }

    /// A pathological feed dump cannot monopolize a run: eligible items cap per source, the
    /// capped source's feed conditional is NOT committed (so the next run re-fetches the feed
    /// and drains the remainder), and other sources are unaffected.
    func testPerSourceItemCapBoundsTheRunAndDrainsNextRun() async throws {
        client.stubs["https://wire.example/feed"] = .init(data: Data(floodFeedXML(count: 3).utf8),
                                                          etag: "W/\"flood-1\"", lastModified: nil)
        client.stubs["https://paper.example/feed"] = .init(data: Data(paperFeedXML().utf8),
                                                           etag: "W/\"paper-1\"", lastModified: nil)
        client.stubs["https://paper.example/bridge"] = .init(data: Data(paperPageHTML().utf8),
                                                             etag: nil, lastModified: nil)
        client.stubs["https://img.example/paper-hero.jpg"] = .init(data: Data("PAPERHEROBYTES".utf8),
                                                                   etag: nil, lastModified: nil)
        let cappedAtTwo: (inout CompilerConfiguration) -> Void = { $0.maxItemsPerSourcePerRun = 2 }

        let stats = try await makeCompiler(configure: cappedAtTwo).run()
        let wireStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "wire" })
        XCTAssertEqual(wireStats.eligibleItems, 2)
        XCTAssertEqual(wireStats.newArticles, 2)
        XCTAssertTrue(wireStats.hitItemCap)
        XCTAssertEqual(stats.newArticles, 3, "paper is unaffected by wire's cap")
        XCTAssertTrue(CompileEditionMain.report(stats).contains("item cap"), "run log names the cap")

        let state = CompilerState.load(from: stateURL)
        XCTAssertNil(state.feedConditionals["https://wire.example/feed"],
                     "a capped source must not commit its conditional or the remainder strands behind 304s")
        XCTAssertNotNil(state.feedConditionals["https://paper.example/feed"])

        // Run 2, same stubs: known GUIDs skip; the remaining flood item drains.
        let stats2 = try await makeCompiler(configure: cappedAtTwo).run()
        let wire2 = try XCTUnwrap(stats2.perSource.first { $0.sourceID == "wire" })
        XCTAssertEqual(wire2.newArticles, 1)
        XCTAssertFalse(wire2.hitItemCap)
        let edition = try decodeEdition()
        XCTAssertEqual(edition.articles.count, 4)
        XCTAssertNotNil(CompilerState.load(from: stateURL).feedConditionals["https://wire.example/feed"],
                        "an uncapped run commits the conditional again")
    }

    /// Exactly cap-many eligible items is NOT a cap hit -- the conditional commits normally.
    func testExactlyCapManyItemsDoesNotTripTheCap() async throws {
        client.stubs["https://wire.example/feed"] = .init(data: Data(floodFeedXML(count: 2).utf8),
                                                          etag: "W/\"flood-2\"", lastModified: nil)
        let stats = try await makeCompiler(catalog: [testCatalog()[0]],
                                           configure: { $0.maxItemsPerSourcePerRun = 2 }).run()
        let wireStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "wire" })
        XCTAssertEqual(wireStats.newArticles, 2)
        XCTAssertFalse(wireStats.hitItemCap)
        XCTAssertNotNil(CompilerState.load(from: stateURL).feedConditionals["https://wire.example/feed"])
    }

    // MARK: - Run budget (finding 3b)

    /// Once the wall-clock budget is spent, no NEW source starts (in-flight sources finish),
    /// but the run still writes the edition + state with what it has and reports success --
    /// the Actions 25-minute kill can never turn a slow run into a total loss.
    func testBudgetExhaustionStopsNewSourcesButShipsWhatItHas() async throws {
        stubAll()
        let clock = MutableClock(start: now)
        // Serial phases make the order deterministic: wire surveys+downloads first.
        // The clock jumps past the 20-minute budget during wire's Phase B image fetch --
        // wire (in-flight) must finish; paper's download must never start.
        client.onRequest = { url in
            if url == "https://img.example/wire-photo.jpg" { clock.advance(by: 21 * 60) }
        }
        let stats = try await makeCompiler { configuration in
            configuration.surveyConcurrency = 1
            configuration.downloadConcurrency = 1
            configuration.now = { clock.now }
        }.run()

        XCTAssertTrue(stats.budgetTruncated)
        XCTAssertEqual(stats.skippedSourceCount, 1)
        XCTAssertEqual(stats.newArticles, 1) // wire finished in-flight
        XCTAssertEqual(client.requestCount(of: "https://paper.example/bridge"), 0,
                       "paper's download must never start after the budget is spent")

        // The partial edition still ships.
        let edition = try decodeEdition()
        XCTAssertEqual(edition.articles.map(\.guid), ["wire-lakefront-1"])

        // wire's checkpoint committed; paper's conditional did NOT (so the next run
        // re-surveys paper's feed and picks its items up).
        let state = CompilerState.load(from: stateURL)
        XCTAssertNotNil(state.feedConditionals["https://wire.example/feed"])
        XCTAssertNil(state.feedConditionals["https://paper.example/feed"])

        // The run log carries the budget-truncated note.
        let report = CompileEditionMain.report(stats)
        XCTAssertTrue(report.contains("BUDGET-TRUNCATED"), report)
    }

    func testUntruncatedRunReportsNoBudgetNote() async throws {
        stubAll()
        let stats = try await makeCompiler().run()
        XCTAssertFalse(stats.budgetTruncated)
        XCTAssertEqual(stats.skippedSourceCount, 0)
        XCTAssertFalse(CompileEditionMain.report(stats).contains("BUDGET"))
    }

    // MARK: - Response-size caps (finding 3e)

    func testEveryFetchCarriesItsSizeCap() async throws {
        stubAll()
        _ = try await makeCompiler().run()
        XCTAssertEqual(client.requestedMaxBytes["https://wire.example/feed"], FetchLimits.pageBytes)
        XCTAssertEqual(client.requestedMaxBytes["https://paper.example/feed"], FetchLimits.pageBytes)
        XCTAssertEqual(client.requestedMaxBytes["https://paper.example/bridge"], FetchLimits.pageBytes)
        XCTAssertEqual(client.requestedMaxBytes["https://img.example/wire-photo.jpg"], FetchLimits.imageBytes)
        XCTAssertEqual(client.requestedMaxBytes["https://img.example/paper-hero.jpg"], FetchLimits.imageBytes)
    }

    func testOversizePageIsAbortedAndNegativeCached() async throws {
        stubAll()
        client.stubs["https://paper.example/bridge"] = .init(data: Data(count: FetchLimits.pageBytes + 1),
                                                             etag: nil, lastModified: nil)
        let stats = try await makeCompiler().run()

        XCTAssertEqual(stats.newArticles, 1) // wire still compiles
        let paperStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "paper" })
        XCTAssertEqual(paperStats.failures, 1)
        // Oversize is deterministic for as long as the page stays oversize -- negative-cached
        // like a gate rejection so half-hourly runs don't re-pull megabytes for 7 days.
        let state = CompilerState.load(from: stateURL)
        XCTAssertTrue(state.isRejected(URL(string: "https://paper.example/bridge")!))
    }

    func testOversizeImageShipsArticleTextFirst() async throws {
        stubAll()
        client.stubs["https://img.example/paper-hero.jpg"] = .init(data: Data(count: FetchLimits.imageBytes + 1),
                                                                   etag: nil, lastModified: nil)
        let stats = try await makeCompiler().run()

        XCTAssertEqual(stats.newArticles, 2)
        let paperStats = try XCTUnwrap(stats.perSource.first { $0.sourceID == "paper" })
        XCTAssertEqual(paperStats.imageFailures, 1)
        let edition = try decodeEdition()
        let paper = try XCTUnwrap(edition.articles.first { $0.sourceID == "paper" })
        XCTAssertNil(paper.topImageURL)
    }

    // MARK: - Attribution

    func testConversationStyleSourceCarriesCreditLine() async throws {
        let atom = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Convo</title>
          <entry>
            <title>Why Bees Matter</title>
            <id>convo-bees-1</id>
            <link rel="alternate" href="https://convo.example/bees"/>
            <published>\(EditionDates.string(from: now.addingTimeInterval(-1800)))</published>
            <author><name>Lisa Cuchara, Professor of Biomedical Sciences, Quinnipiac University</name></author>
            <content type="html">&lt;p&gt;\(longParagraph)&lt;/p&gt;&lt;p&gt;\(longParagraph)&lt;/p&gt;&lt;p&gt;\(longParagraph)&lt;/p&gt;</content>
          </entry>
        </feed>
        """
        client.stubs["https://convo.example/feed"] = .init(data: Data(atom.utf8), etag: nil, lastModified: nil)
        let catalog = [SourceConfig(id: "convo", name: "Convo", feeds: [
            FeedEndpoint(url: URL(string: "https://convo.example/feed")!, defaultCategory: .us)
        ], strategy: .feedFullText, weight: 1.0, bodySelector: nil,
           excludeURLPatterns: [], maxPerDay: 40, requiresAttribution: true)]

        _ = try await makeCompiler(catalog: catalog).run()
        let edition = try decodeEdition()
        XCTAssertEqual(edition.articles.count, 1)
        XCTAssertEqual(edition.articles[0].author, "Lisa Cuchara")
        XCTAssertEqual(edition.articles[0].attribution,
                       "by Lisa Cuchara, Quinnipiac University — from The Conversation (CC BY-ND 4.0)")
    }

    // MARK: - Bounded concurrency helper

    func testBoundedConcurrentMapPreservesOrderAndBoundsParallelism() async {
        let counter = ParallelismCounter()
        let inputs = Array(0..<20)
        let results = await boundedConcurrentMap(inputs, limit: 3) { value -> Int in
            await counter.enter()
            try? await Task.sleep(nanoseconds: 5_000_000)
            await counter.exit()
            return value * 2
        }
        XCTAssertEqual(results, inputs.map { $0 * 2 })
        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "should actually run concurrently")
    }
}

/// Controllable wall clock for the run-budget tests (finding 3b).
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

actor ParallelismCounter {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func exit() { current -= 1 }
}
