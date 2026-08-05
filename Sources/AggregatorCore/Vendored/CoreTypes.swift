import Foundation

enum FetchStrategy: String, Codable {
    case feedFullText, pageExtract
}

struct FeedEndpoint: Sendable {
    let url: URL
    let defaultCategory: ArticleCategory
}

struct SourceConfig: Identifiable, Sendable {
    let id: String
    let name: String
    let feeds: [FeedEndpoint]
    let strategy: FetchStrategy
    let weight: Double
    let bodySelector: String?
    let excludeURLPatterns: [String]
    let maxPerDay: Int
    /// Recency-decay half-life used by StackRanker (v1.1 tiered decay). Defaults to the v1
    /// global half-life (12h) so every pre-v1.1 call site that doesn't pass this explicitly
    /// (tests, ad hoc configs) keeps its old ranking behavior unchanged.
    let decayHalfLifeHours: Double
    /// v1.3.1 item 2: title-prefix exclusion at ingest, alongside `excludeURLPatterns` -- for
    /// junk whose URL gives no clean structural signal but whose title always starts the same
    /// way (NY Post/pagesix.com streaming-promo listicles: "How to watch ... on Hulu/Netflix/
    /// ...", confirmed live 2026-07-27 to sit under an ordinary /entertainment/ URL slug, not a
    /// dedicated section `excludeURLPatterns` could cleanly target). Case-insensitive prefix
    /// match against the feed item's title. Defaults to `[]` so every existing call site keeps
    /// compiling unchanged, same convention as `decayHalfLifeHours` above.
    let excludeTitlePrefixes: [String]
    /// v1.3.1 item 4 ("Read more" junk mid-article): per-source CSS selectors for whole junk
    /// subtrees to strip before extraction, alongside the fixed generic set
    /// (`ContentExtractor.stripJunk`'s "script, style, nav, aside, .related"). NY Post's
    /// newsletter-signup widget (confirmed live 2026-07-27: `.single__inline-module`) isn't
    /// just a stray promo paragraph -- it also renders a fake `<h3>` "heading" that a plain
    /// paragraph-text filter can't catch, so the whole subtree needs removing. Defaults to `[]`,
    /// same convention as `decayHalfLifeHours`/`excludeTitlePrefixes` above.
    let junkSelectors: [String]
    /// v1.3.1 item 7 (NBC News): when true, an item's `<guid>` replaces its `<link>` as the
    /// article URL whenever the guid itself parses as an absolute http(s) URL -- confirmed live
    /// 2026-07-27 that NBC's `<link>` can point somewhere other than the real article (a video
    /// page, or the homepage) while `<guid isPermaLink="true">` carries the genuine article URL.
    /// See `FeedParser.applyGUIDAsURLPreference`. Defaults to `false`, same convention as the
    /// other optional fields above.
    let preferGUIDAsURL: Bool
    /// v1.4 fix round 1 (Important 2): sources that structurally cover the same stories as each
    /// other -- same-market duopolies (Chicago Sun-Times + WBEZ's editorial partnership; ABC7 +
    /// NBC5, Chicago's two local TV affiliates; ABC7 + ABC News, an O&O relationship; NBC5 + NBC
    /// News likewise) -- share at least one `marketGroups` tag so `StoryClusterer` counts them as
    /// ONE toward a cluster's independent-source count instead of two, per
    /// `.superpowers/sdd/corroboration-by-section.md`'s finding that 100% of Chicago's
    /// "cross-source" clusters were actually a structural pair, not independent verification.
    ///
    /// A `Set`, not a single `String?` (v1.3.3's original shape) -- abc7 is simultaneously a
    /// Chicago TV affiliate (with nbc5) AND an ABC owned-and-operated station (with abcnews), and
    /// a single-valued field couldn't express both memberships at once (see the v1.4 report's
    /// "Concerns" section: abc7+abcnews was undercounting as 2 independent voices, in exactly the
    /// national-news context where corroboration carries the most weight). Two sources are the
    /// SAME independent voice if their `marketGroups` sets INTERSECT, not merely match exactly --
    /// computed via `StoryClusterer.independentGroups`'s connected-components grouping, so abc7's
    /// dual membership transitively bridges nbc5 and abcnews together too. Over-collapsing is the
    /// conservative, evidence-favored direction here. Empty (the default) means "no group, counts
    /// independently" -- every national source. See `SourceCatalog` for the actual assignments.
    let marketGroups: Set<String>
    /// v1.8: true for a source whose licence *requires* a visible author/institution credit on
    /// every article page (The Conversation's CC BY-ND 4.0 -- see `SourceCatalog`'s "conversation"
    /// entry). Deliberately a per-source flag rather than a hardcoded `sourceID == "conversation"`
    /// check anywhere else in the app (spec, v1.8 item 2): `ArticleGate` uses it to reject an
    /// article with no extractable attribution at all (item 3), and `ArticleView` uses it to gate
    /// the credit line so the other 25 sources' reader pages render exactly as before (storing
    /// `author`/`authorInstitution` happens for every source regardless of this flag -- it's only
    /// DISPLAY and the ingest gate that key off it). Defaults to `false`, same convention as every
    /// other optional field above.
    let requiresAttribution: Bool

    init(
        id: String,
        name: String,
        feeds: [FeedEndpoint],
        strategy: FetchStrategy,
        weight: Double,
        bodySelector: String?,
        excludeURLPatterns: [String],
        maxPerDay: Int,
        decayHalfLifeHours: Double = 12.0,
        excludeTitlePrefixes: [String] = [],
        junkSelectors: [String] = [],
        preferGUIDAsURL: Bool = false,
        marketGroups: Set<String> = [],
        requiresAttribution: Bool = false
    ) {
        self.id = id
        self.name = name
        self.feeds = feeds
        self.strategy = strategy
        self.weight = weight
        self.bodySelector = bodySelector
        self.excludeURLPatterns = excludeURLPatterns
        self.maxPerDay = maxPerDay
        self.decayHalfLifeHours = decayHalfLifeHours
        self.excludeTitlePrefixes = excludeTitlePrefixes
        self.junkSelectors = junkSelectors
        self.preferGUIDAsURL = preferGUIDAsURL
        self.marketGroups = marketGroups
        self.requiresAttribution = requiresAttribution
    }
}

struct FeedItem: Equatable, Sendable {
    let guid: String
    let url: URL
    let title: String
    let summary: String?
    let publishedAt: Date?
    let feedCategories: [String]
    let contentHTML: String?
    let imageURLs: [URL]
    /// v1.8: the feed's own byline, when present -- Atom's `<author><name>` or RSS's
    /// `<dc:creator>` (see `FeedParser`). This is the raw feed-supplied string (The Conversation's
    /// Atom feed combines name/title/institution into one `<name>` value, e.g. "Lisa Cuchara,
    /// Professor of Biomedical Sciences, Quinnipiac University" -- live-verified 2026-07-29), NOT
    /// yet split into author/institution -- `ContentExtractor` does that splitting, only as a
    /// fallback when the article page itself yields nothing (spec: "falling back to the feed's
    /// <author><name> / dc:creator where the page yields nothing"). Defaults to `nil` so every
    /// existing call site keeps compiling unchanged, same convention as every other optional
    /// `FeedItem` field.
    let author: String?

    init(
        guid: String, url: URL, title: String, summary: String?, publishedAt: Date?,
        feedCategories: [String], contentHTML: String?, imageURLs: [URL], author: String? = nil
    ) {
        self.guid = guid
        self.url = url
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.feedCategories = feedCategories
        self.contentHTML = contentHTML
        self.imageURLs = imageURLs
        self.author = author
    }
}

struct BodyBlock: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable {
        case paragraph, heading, image
    }
    var kind: Kind
    var text: String?
    var imageURLString: String?
    var caption: String?
    var credit: String?

    /// Combines a caption + credit into a single `" — "`-joined display string, treating each
    /// as absent when nil or empty. Cheap minor #7 (review fix round): shared by every
    /// caption/credit UI (`PhotoZoomView.captionCreditText`, `ArticleBodyView`'s inline image
    /// caption) so a credit-only block -- no caption text, just a photographer credit --
    /// actually renders instead of silently vanishing. Previously each call site independently
    /// gated its whole caption+credit `Text` on `caption` alone (`if let caption { ... }`), so
    /// a nil/empty caption dropped a present credit along with it.
    static func captionCreditText(caption: String?, credit: String?) -> String? {
        let trimmedCaption = (caption?.isEmpty == false) ? caption : nil
        let trimmedCredit = (credit?.isEmpty == false) ? credit : nil
        switch (trimmedCaption, trimmedCredit) {
        case let (c?, r?): return c + " — " + r
        case let (c?, nil): return c
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }
}

struct ExtractedArticle: Equatable {
    let title: String
    let byline: String?
    let bodyBlocks: [BodyBlock]
    let heroImageURL: URL?
    var allImageURLs: [URL]
    /// v1.8: the article's author and their institution, generic across every source (spec item
    /// 1 -- "store these for every source where they are available... cost nothing"), populated
    /// by `ContentExtractor` from the article page's own byline markup, falling back to the
    /// feed-supplied `FeedItem.author` when the page yields nothing. `nil`/`nil` for the (large)
    /// majority of sources that don't expose either -- this is a plain "we don't know," not an
    /// error. Storing these is NOT the same as displaying them: see `ArticleView`'s credit line
    /// and `SourceConfig.requiresAttribution` for the (separate, opt-in) display gate.
    var author: String? = nil
    var authorInstitution: String? = nil
    /// v1.12: the article's own URL, populated by `ContentExtractor` from the `FeedItem`/page
    /// URL it extracted from -- NOT previously carried on this type at all (extraction only
    /// returned parsed CONTENT; nothing needed the source URL downstream of it). `ArticleGate`'s
    /// language filter needs it for the Sun-Times "La Voz Chicago" structural check
    /// (`LanguageFilter.isKnownNonEnglishURL`, a `/la-voz/` URL path segment) -- a fast,
    /// deterministic PRIMARY rule that runs before the general on-device language-detection
    /// fallback, which needs no URL at all. Defaults to `nil` so every pre-v1.12 call site
    /// (every test that constructs `ExtractedArticle` directly) keeps compiling unchanged; a
    /// `nil` URL just skips straight to the general fallback, same as any other source.
    var url: URL? = nil
}
