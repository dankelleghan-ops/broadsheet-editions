import Foundation

/// Cross-run state the GitHub Actions workflow caches between runs (actions/cache on the state
/// file path). This is what makes steady-state runs cheap: feeds are re-fetched conditionally
/// (ETag / Last-Modified), already-compiled articles are never re-fetched or re-extracted, and
/// gate-rejected URLs are skipped for 7 days (mirroring the app's `GateRejectionStore`
/// retention) instead of being futilely re-fetched every 30 minutes.
struct CompilerState: Codable, Equatable {
    var schemaVersion: Int = 1
    /// Keyed by feed URL string.
    var feedConditionals: [String: FeedConditional] = [:]
    /// Every article currently inside the window, with everything needed to re-emit it
    /// without re-fetching.
    var articles: [CompiledArticle] = []
    /// URL string -> when it was (last) rejected. Mirrors the app's GateRejectionStore:
    /// deterministic gate failures and missing-full-text feed items, never transient
    /// network failures.
    var rejectedURLs: [String: Date] = [:]

    /// Mirrors `GateRejectionStore.retentionSeconds` (7 days).
    static let rejectionRetentionSeconds: TimeInterval = 7 * 24 * 3600

    static func load(from url: URL) -> CompilerState {
        guard let data = try? Data(contentsOf: url) else { return CompilerState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(CompilerState.self, from: data) else {
            // A corrupt or incompatible state file is never fatal -- start fresh (the run
            // just does more work once).
            return CompilerState()
        }
        return state
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Drops articles that have aged out of the window and rejections past retention.
    mutating func prune(now: Date, windowSeconds: TimeInterval) {
        let articleCutoff = now.addingTimeInterval(-windowSeconds)
        articles.removeAll { $0.publishedAt < articleCutoff }
        let rejectionCutoff = now.addingTimeInterval(-Self.rejectionRetentionSeconds)
        rejectedURLs = rejectedURLs.filter { $0.value >= rejectionCutoff }
    }

    func isRejected(_ url: URL) -> Bool {
        rejectedURLs[url.absoluteString] != nil
    }

    mutating func recordRejection(_ url: URL, now: Date) {
        rejectedURLs[url.absoluteString] = now
    }
}

struct FeedConditional: Codable, Equatable {
    var etag: String?
    var lastModified: String?

    var isEmpty: Bool { etag == nil && lastModified == nil }
}

/// A fully-compiled article: everything the edition needs, so retained articles cost zero
/// fetches on later runs.
struct CompiledArticle: Codable, Equatable {
    var guid: String
    var url: String
    var sourceID: String
    var title: String
    var author: String?
    var attribution: String?
    /// The app's convention: `item.publishedAt ?? now` at first compile (an undated item
    /// windows out 48h after first sight).
    var publishedAt: Date
    var bodyBlocksJSON: String
    /// Content hash of the resized JPEG (first 16 hex of sha256) -- the image's filename in
    /// images/. nil = article has no usable hero image.
    var imageSHA16: String?
    /// The original remote hero URL, kept so a run that lost the output-dir cache can
    /// re-download and re-resize the image for a retained article.
    var imageSourceURL: String?
}
