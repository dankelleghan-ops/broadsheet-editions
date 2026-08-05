import XCTest
@testable import AggregatorCore

/// EDITION FORMAT CONTRACT v1 -- these tests pin the wire shape both halves build against.
final class EditionContractTests: XCTestCase {

    private func sampleBlocks() -> [BodyBlock] {
        [
            BodyBlock(kind: .paragraph, text: "First paragraph of prose.", imageURLString: nil, caption: nil, credit: nil),
            BodyBlock(kind: .image, text: nil, imageURLString: "https://example.com/photo.jpg",
                      caption: "A caption", credit: "A photographer"),
            BodyBlock(kind: .heading, text: "A subhead", imageURLString: nil, caption: nil, credit: nil),
            BodyBlock(kind: .paragraph, text: "Closing paragraph.", imageURLString: nil, caption: nil, credit: nil)
        ]
    }

    /// bodyBlocksJSON must be EXACTLY the app's persisted encoder SHAPE:
    /// `JSONEncoder().encode(extracted.bodyBlocks)` with default configuration -- same key
    /// set, same value encoding, nils omitted. (Foundation's default JSONEncoder does not
    /// guarantee KEY ORDER across encoder instances -- the app's own persisted bytes wouldn't
    /// re-encode byte-identically either -- so shape is compared as parsed JSON, exactly what
    /// the phone's JSONDecoder consumes.)
    func testBodyBlocksJSONMatchesAppEncoderShape() throws {
        let blocks = sampleBlocks()
        let appBytes = try JSONEncoder().encode(blocks) // the exact ArticleStore call
        let editionString = try BodyBlockJSON.encode(blocks)
        let appObject = try JSONSerialization.jsonObject(with: appBytes) as? NSArray
        let editionObject = try JSONSerialization.jsonObject(with: Data(editionString.utf8)) as? NSArray
        XCTAssertEqual(editionObject, appObject)
        // And the app-side decode of the edition string yields the identical blocks.
        XCTAssertEqual(try JSONDecoder().decode([BodyBlock].self, from: Data(editionString.utf8)), blocks)
    }

    func testBodyBlocksJSONOmitsNilFields() throws {
        let editionString = try BodyBlockJSON.encode([
            BodyBlock(kind: .paragraph, text: "Only text.", imageURLString: nil, caption: nil, credit: nil)
        ])
        // Synthesized Codable omits nil optionals -- the phone's decoder relies on that shape.
        XCTAssertFalse(editionString.contains("imageURLString"))
        XCTAssertFalse(editionString.contains("caption"))
        XCTAssertFalse(editionString.contains("credit"))
        XCTAssertTrue(editionString.contains("\"kind\":\"paragraph\""))
    }

    func testBodyBlocksJSONRoundTripsThroughAppDecoder() throws {
        let blocks = sampleBlocks()
        let editionString = try BodyBlockJSON.encode(blocks)
        // What the phone will do on ingest: decode the string straight into [BodyBlock].
        let decoded = try JSONDecoder().decode([BodyBlock].self, from: Data(editionString.utf8))
        XCTAssertEqual(decoded, blocks)
    }

    func testEditionEnvelopeShape() throws {
        let article = EditionArticle(
            guid: "https://example.com/a-story", url: "https://example.com/a-story",
            sourceID: "guardian", title: "A headline", author: "Jane Reporter",
            publishedAt: "2026-08-05T12:00:00Z",
            bodyBlocksJSON: try BodyBlockJSON.encode(sampleBlocks()),
            topImageURL: "https://pages.example/edition/images/0123456789abcdef.jpg",
            attribution: nil
        )
        let edition = Edition(schemaVersion: 1, generatedAt: "2026-08-05T13:30:00Z",
                              windowHours: 48, articles: [article])
        let data = try edition.encodedJSON()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["generatedAt"] as? String, "2026-08-05T13:30:00Z")
        XCTAssertEqual(object["windowHours"] as? Int, 48)
        let articles = try XCTUnwrap(object["articles"] as? [[String: Any]])
        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles[0]["guid"] as? String, "https://example.com/a-story")
        XCTAssertEqual(articles[0]["sourceID"] as? String, "guardian")
        XCTAssertEqual(articles[0]["topImageURL"] as? String,
                       "https://pages.example/edition/images/0123456789abcdef.jpg")
        // Optional-nil fields are omitted, not null.
        XCTAssertNil(articles[0]["attribution"])
        // The nested bodyBlocksJSON survives as a STRING the phone decodes separately.
        let bodyString = try XCTUnwrap(articles[0]["bodyBlocksJSON"] as? String)
        let decodedBlocks = try JSONDecoder().decode([BodyBlock].self, from: Data(bodyString.utf8))
        XCTAssertEqual(decodedBlocks, sampleBlocks())
    }

    func testEditionRoundTrip() throws {
        let edition = Edition(
            schemaVersion: 1, generatedAt: "2026-08-05T13:30:00Z", windowHours: 48,
            articles: [
                EditionArticle(guid: "g1", url: "https://example.com/1", sourceID: "npr",
                               title: "T1", author: nil, publishedAt: "2026-08-05T10:00:00Z",
                               bodyBlocksJSON: "[]", topImageURL: nil,
                               attribution: "by A, B — from The Conversation (CC BY-ND 4.0)")
            ]
        )
        let decoded = try JSONDecoder().decode(Edition.self, from: edition.encodedJSON())
        XCTAssertEqual(decoded, edition)
    }

    func testEditionDatesAreUTCInternetDateTime() {
        let date = Date(timeIntervalSince1970: 1_754_400_000)
        let string = EditionDates.string(from: date)
        XCTAssertTrue(string.hasSuffix("Z"), "contract dates are UTC: \(string)")
        XCTAssertEqual(EditionDates.date(from: string), date)
    }

    /// The attribution field carries the app's exact v1.8 credit line.
    func testAttributionUsesVendoredCreditLine() {
        XCTAssertEqual(
            AttributionText.creditLine(author: "Lisa Cuchara", institution: "Quinnipiac University"),
            "by Lisa Cuchara, Quinnipiac University — from The Conversation (CC BY-ND 4.0)"
        )
        XCTAssertNil(AttributionText.creditLine(author: nil, institution: nil))
    }
}
