import XCTest
@testable import AggregatorCore

final class SHA256Tests: XCTestCase {
    /// NIST FIPS 180-4 test vectors.
    func testKnownVectors() {
        XCTAssertEqual(SHA256.hexDigest(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hexDigest(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// Multi-block message (> 64 bytes) exercises the chunk loop.
    func testLongInput() {
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(SHA256.hexDigest(million),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testHexDigest16IsPrefix() {
        let data = Data("abc".utf8)
        XCTAssertEqual(SHA256.hexDigest16(data), "ba7816bf8f01cfea")
        XCTAssertEqual(SHA256.hexDigest16(data).count, 16)
    }
}

final class ImageProcessorTests: XCTestCase {
    func testImageMagickArguments() {
        let argv = ImageProcessor.imageMagickArguments(toolPath: "/usr/bin/convert",
                                                       input: "/tmp/in.png", output: "/tmp/out.jpg")
        XCTAssertEqual(argv, [
            "/usr/bin/convert", "/tmp/in.png",
            "-auto-orient",
            "-resize", "1400x1400>",
            "-background", "white", "-alpha", "remove", "-alpha", "off",
            "-strip",
            "-quality", "72",
            "jpeg:/tmp/out.jpg"
        ])
    }

    func testSipsResizeOnlyShrinksLargeImages() {
        // Longest edge over the cap: -Z present.
        let large = ImageProcessor.sipsResizeArguments(toolPath: "/usr/bin/sips", input: "/tmp/in.png",
                                                       output: "/tmp/out.jpg", probedLongestEdge: 4000)
        XCTAssertTrue(large.contains("-Z"))
        XCTAssertEqual(large[large.firstIndex(of: "-Z")! + 1], "1400")
        // At or under the cap: no -Z (sips -Z would UPSCALE a smaller image -- must not).
        let small = ImageProcessor.sipsResizeArguments(toolPath: "/usr/bin/sips", input: "/tmp/in.png",
                                                       output: "/tmp/out.jpg", probedLongestEdge: 900)
        XCTAssertFalse(small.contains("-Z"))
        let exact = ImageProcessor.sipsResizeArguments(toolPath: "/usr/bin/sips", input: "/tmp/in.png",
                                                       output: "/tmp/out.jpg", probedLongestEdge: 1400)
        XCTAssertFalse(exact.contains("-Z"))
    }

    func testSipsArgumentsCarryQualityAndFormat() {
        let argv = ImageProcessor.sipsResizeArguments(toolPath: "sips", input: "in", output: "out",
                                                      probedLongestEdge: 2000)
        XCTAssertEqual(argv, ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "72",
                              "-Z", "1400", "in", "--out", "out"])
    }

    func testParseSipsProbeOutput() throws {
        let output = """
        /tmp/in.png
          pixelWidth: 2048
          pixelHeight: 1365
        """
        XCTAssertEqual(try ImageProcessor.parseSipsProbeOutput(output), 2048)
        XCTAssertThrowsError(try ImageProcessor.parseSipsProbeOutput("no dims here"))
    }

    func testDetectToolPrefersImageMagick() {
        let tool = ImageProcessor.detectTool(findExecutable: { name in
            name == "magick" ? "/opt/magick" : (name == "sips" ? "/usr/bin/sips" : nil)
        })
        XCTAssertEqual(tool, .magick(path: "/opt/magick"))
        let convertOnly = ImageProcessor.detectTool(findExecutable: { name in
            name == "convert" ? "/usr/bin/convert" : nil
        })
        XCTAssertEqual(convertOnly, .convert(path: "/usr/bin/convert"))
        let sipsOnly = ImageProcessor.detectTool(findExecutable: { name in
            name == "sips" ? "/usr/bin/sips" : nil
        })
        XCTAssertEqual(sipsOnly, .sips(path: "/usr/bin/sips"))
        XCTAssertNil(ImageProcessor.detectTool(findExecutable: { _ in nil }))
    }
}

final class CompilerStateTests: XCTestCase {
    private func article(guid: String, publishedAt: Date) -> CompiledArticle {
        CompiledArticle(guid: guid, url: "https://example.com/\(guid)", sourceID: "npr",
                        title: "T", author: nil, attribution: nil, publishedAt: publishedAt,
                        bodyBlocksJSON: "[]", imageSHA16: nil, imageSourceURL: nil)
    }

    func testPruneDropsAgedArticlesAndKeepsWindowed() {
        let now = Date()
        var state = CompilerState()
        state.articles = [
            article(guid: "old", publishedAt: now.addingTimeInterval(-49 * 3600)),
            article(guid: "fresh", publishedAt: now.addingTimeInterval(-2 * 3600))
        ]
        state.prune(now: now, windowSeconds: 48 * 3600)
        XCTAssertEqual(state.articles.map(\.guid), ["fresh"])
    }

    func testPruneExpiresRejectionsAtSevenDays() {
        let now = Date()
        var state = CompilerState()
        state.rejectedURLs = [
            "https://example.com/stale": now.addingTimeInterval(-8 * 24 * 3600),
            "https://example.com/recent": now.addingTimeInterval(-6 * 24 * 3600)
        ]
        state.prune(now: now, windowSeconds: 48 * 3600)
        XCTAssertEqual(Array(state.rejectedURLs.keys), ["https://example.com/recent"])
        XCTAssertTrue(state.isRejected(URL(string: "https://example.com/recent")!))
        XCTAssertFalse(state.isRejected(URL(string: "https://example.com/stale")!))
    }

    func testSaveAndLoadRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_754_000_000) // whole second for ISO8601 fidelity
        var state = CompilerState()
        state.feedConditionals["https://feed.example/rss"] = FeedConditional(etag: "W/\"abc\"", lastModified: nil)
        state.articles = [article(guid: "g", publishedAt: now)]
        state.recordRejection(URL(string: "https://example.com/bad")!, now: now)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try state.save(to: url)
        let loaded = CompilerState.load(from: url)
        XCTAssertEqual(loaded, state)
    }

    func testLoadMissingOrCorruptFileStartsFresh() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).json")
        XCTAssertEqual(CompilerState.load(from: missing), CompilerState())

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        XCTAssertEqual(CompilerState.load(from: corrupt), CompilerState())
    }
}

final class GzipWriterTests: XCTestCase {
    func testWritesDecodableGzip() throws {
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-\(UUID().uuidString)/edition.json.gz")
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        try GzipWriter.writeGzipped(payload, to: outputURL)

        let magic = try Data(contentsOf: outputURL).prefix(2)
        XCTAssertEqual([UInt8](magic), [0x1f, 0x8b], "gzip magic bytes")
        let result = try ProcessRunner.run(["gunzip", "-c", outputURL.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, payload)
    }
}

final class CompileEditionArgumentTests: XCTestCase {
    func testParsesFlagsAndDefaults() throws {
        let args = try CompileEditionMain.parseArguments(["--out", "/tmp/edition-out"])
        XCTAssertEqual(args.outDirectory.path, "/tmp/edition-out")
        XCTAssertEqual(args.windowHours, 48)
        // Default state file sits NEXT TO the out dir, never inside it (out dir is what gets
        // force-pushed to gh-pages).
        XCTAssertEqual(args.stateFileURL.path, "/tmp/edition-out-state.json")
        XCTAssertFalse(args.stateFileURL.path.hasPrefix(args.outDirectory.path + "/"))
    }

    func testExplicitStateAndBaseURL() throws {
        let args = try CompileEditionMain.parseArguments([
            "--out", "/tmp/o", "--state", "/tmp/s.json",
            "--base-url", "https://pages.example/edition/", "--window-hours", "24"
        ])
        XCTAssertEqual(args.stateFileURL.path, "/tmp/s.json")
        XCTAssertEqual(args.baseURL, "https://pages.example/edition/")
        XCTAssertEqual(args.windowHours, 24)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try CompileEditionMain.parseArguments([]))
        XCTAssertThrowsError(try CompileEditionMain.parseArguments(["--out"]))
        XCTAssertThrowsError(try CompileEditionMain.parseArguments(["--out", "/tmp/o", "--bogus"]))
        XCTAssertThrowsError(try CompileEditionMain.parseArguments(["--out", "/tmp/o", "--window-hours", "zero"]))
    }
}
