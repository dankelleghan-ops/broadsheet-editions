import Foundation

// MARK: - EDITION FORMAT CONTRACT v1
//
// Published at <base>/edition.json.gz (gzip JSON) and <base>/images/<sha256-16>.jpg.
// Neither the app half nor this server half may change this shape unilaterally -- see
// aggregator/README.md for the full contract text.

struct Edition: Codable, Equatable {
    /// Always 1 for this contract version.
    let schemaVersion: Int
    /// ISO8601 UTC, e.g. "2026-08-05T21:14:09Z".
    let generatedAt: String
    /// Always 48 for this contract version.
    let windowHours: Int
    let articles: [EditionArticle]
}

struct EditionArticle: Codable, Equatable {
    /// The app's existing guid convention per source (FeedParser: item `<guid>`/Atom `<id>`,
    /// falling back to the link string) -- the phone dedups by this exactly as it does for its
    /// own fetches.
    let guid: String
    let url: String
    /// Must match SourceCatalog IDs.
    let sourceID: String
    let title: String
    let author: String?
    /// ISO8601 UTC.
    let publishedAt: String
    /// EXACTLY the app's persisted BodyBlock array JSON -- the same
    /// `JSONEncoder().encode([BodyBlock])` shape ArticleStore writes to `Article.bodyJSON`.
    /// See `BodyBlockJSON.encode`.
    let bodyBlocksJSON: String
    /// Absolute URL into <base>/images/, or nil when the article has no hero image (or its
    /// download/resize failed -- the article still ships, text-first).
    let topImageURL: String?
    /// The v1.8 Conversation credit line when the source requires attribution, else nil.
    let attribution: String?
    /// ADDITIVE optional field (2026-10-12): `true` only when no real publish time could be found for
    /// this article (no usable feed date, none on the page) and `publishedAt` is the compiler's
    /// first-seen time. Omitted otherwise, so the bundle stays the same size and builds that predate
    /// the field never see it. Contract v1 is otherwise unchanged.
    var dateIsEstimated: Bool? = nil
    /// ADDITIVE optional field (sections, 2026-10-18): the `Topic` raw value ("business", "sports", "tech", "scienceHealth",
    /// "climate", "arts", "books", "food", "travel", "style", "realEstate", "obituaries") of the TOPIC FEED the compiler fetched
    /// this article through (`FeedEndpoint.topicHint` in the vendored catalog). Omitted for an article that came through a
    /// main-news feed, so a bundle with no topic feeds is byte-for-byte what it always was, and builds that predate the field
    /// never see it. The app files the article under that topic and counts it against its own daily allowance, not the source's
    /// main cap. Contract v1 is otherwise unchanged.
    var topicHint: String? = nil
}

/// The one true bodyBlocks encoder: the exact call `ArticleStore.downloadItems` makes
/// (`JSONEncoder().encode(extracted.bodyBlocks)`, default configuration -- same key set, same
/// value encoding, nil optionals omitted). Foundation's default JSONEncoder does not guarantee
/// KEY ORDER across encoder instances, so "same encoder shape" -- what the phone's JSONDecoder
/// consumes -- is the contract, not byte order. Pinned by
/// `EditionContractTests.testBodyBlocksJSONMatchesAppEncoderShape`.
enum BodyBlockJSON {
    static func encode(_ blocks: [BodyBlock]) throws -> String {
        let data = try JSONEncoder().encode(blocks)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EditionError.bodyBlocksNotUTF8
        }
        return string
    }
}

enum EditionError: Error, Equatable {
    case bodyBlocksNotUTF8
    case outputEncodingFailed
}

/// Contract date format: ISO8601 with UTC ("Z") timezone, second precision.
enum EditionDates {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

extension Edition {
    /// Deterministic envelope bytes: sorted keys, no pretty-printing (size matters -- the
    /// bundle target is < ~8MB gzipped). The `bodyBlocksJSON` STRINGS inside stay exactly as
    /// `BodyBlockJSON.encode` produced them (JSON string escaping does not alter the decoded
    /// bytes the phone reads back).
    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
