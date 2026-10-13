import XCTest
@testable import AggregatorCore

/// The vendored catalog's BBC entry must carry the caption-label rule too: BBC puts `<span class="visually-hidden">
/// Image caption, </span>` inside every figcaption, so without `figcaption .visually-hidden` in its `junkSelectors`
/// every BBC caption in the edition began "Image caption, ". The app suite's BBCCaptionLabelTests pins the rule in
/// depth; this pins that the compiler's copy of the catalog and extractor does the same on the real captures.
final class BBCCaptionLabelParityTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BroadsheetTests/Fixtures")
    }

    private func captions(of fixtureName: String) throws -> [String] {
        let bbc = try XCTUnwrap(SourceCatalog.all.first { $0.id == "bbc" })
        let url = URL(string: "https://www.bbc.co.uk/news/articles/x")!
        let html = try String(contentsOf: fixturesDir.appendingPathComponent(fixtureName), encoding: .utf8)
        let item = FeedItem(guid: url.absoluteString, url: url, title: "Fixture", summary: nil, publishedAt: nil,
                            feedCategories: [], contentHTML: nil, imageURLs: [])
        let article = try ContentExtractor().extract(fromPageHTML: html, articleURL: url, item: item, config: bbc)
        return article.bodyBlocks.filter { $0.kind == .image }.compactMap(\.caption)
    }

    func testRealBBCCaptionsCarryNoScreenReaderLabel() throws {
        XCTAssertEqual(try captions(of: "page-bbc-sport-branded.html"),
                       ["Players from Real Madrid and Barcelona joined strike action in Spain's Liga F in 2023, as unions sought improved pay and conditions"])
        XCTAssertEqual(try captions(of: "page-bbc-africa-podcasts.html"),
                       ["Lt Gen Shadrack Sibiya has denied all the charges against him"])
        XCTAssertEqual(try captions(of: "page-bbc-lead-photo-after-paragraphs.html"),
                       ["HSI agents loading a box outside the residence"])
        XCTAssertEqual(try captions(of: "page-bbc-no-lead-photo.html"),
                       ["Smoke and flames seen at King Khalid airport in Riyadh on 8 October"])
        XCTAssertEqual(try captions(of: "page-bbc-og-separate-upload.html"),
                       ["A protester before the firing squad execution of Mikal Mahdi in 2025",
                        "At San Quentin prison in California, officials used a gas chamber to execute some people until 1993"])
    }

    func testTheTwoEarlierBBCJunkSelectorsAreStillThere() throws {
        let selectors = try XCTUnwrap(SourceCatalog.all.first { $0.id == "bbc" }).junkSelectors
        XCTAssertTrue(selectors.contains("[data-testid=topic-list]"))
        XCTAssertTrue(selectors.contains("[data-block=promoList]"))
        XCTAssertTrue(selectors.contains("figcaption .visually-hidden"))
    }
}
