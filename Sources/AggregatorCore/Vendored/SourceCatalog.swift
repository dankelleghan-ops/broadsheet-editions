import Foundation

enum SourceCatalog {
    // v1.1 tiered recency decay (Tier-1 ride-along #4): fast half-life for high-volume/
    // breaking-news sources, standard for the v1 default, slow for sources that publish less
    // often but whose stories stay relevant longer (investigative/alt-weekly). See
    // StackRanker, which reads `decayHalfLifeHours` per source instead of a global 12h.
    private static let fastDecayHours = 3.5
    private static let standardDecayHours = 12.0
    private static let slowDecayHours = 24.0

    static let all: [SourceConfig] = [
        SourceConfig(
            id: "guardian",
            name: "The Guardian",
            feeds: [
                FeedEndpoint(url: URL(string: "https://theguardian.com/world/rss")!, defaultCategory: .world),
                FeedEndpoint(url: URL(string: "https://theguardian.com/us-news/rss")!, defaultCategory: .us)
            ],
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: "#maincontent",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "npr",
            name: "NPR",
            feeds: [
                // v1.1 NPR feed repair: live-verified 2026-07-27 (curl against
                // feeds.npr.org/*/rss.xml). 1001 ("NPR Topics: News") is still healthy. 1004,
                // previously mapped here to defaultCategory .politics, now actually serves
                // "NPR Topics: World" -- NPR appears to have silently reassigned that topic
                // ID rather than deprecating per-topic feeds outright. A genuine, fresh
                // "NPR Topics: Politics" feed exists at ID 1014, so it replaces 1004 here
                // (both topical endpoints are kept, per the spec, since working ones exist).
                FeedEndpoint(url: URL(string: "https://feeds.npr.org/1001/rss.xml")!, defaultCategory: .us),
                // v1.1 category/section reconciliation: defaultCategory is a PLACE now, not a
                // topic -- .us, not .politics (the "politics" flavor lives in subtopicRaw,
                // via SubtopicClassifier's Stage-2 keyword fallback for NPR).
                FeedEndpoint(url: URL(string: "https://feeds.npr.org/1014/rss.xml")!, defaultCategory: .us),
                // v1.7 §4: "NPR Topics: Opinion" -- found live-verified 2026-07-29 while
                // investigating npr.org/sections/opinion/ per the spec's browser-based
                // vertical check. Turned out NOT to need any browser rendering at all (the
                // section page itself is server-rendered and a plain `curl` on this feed URL
                // works exactly like NPR's other two topical feeds above): its post-render
                // `<link rel=alternate type=application/rss+xml>` pointed at
                // feeds.npr.org/1057/rss.xml, channel title "NPR Topics: Opinion", real
                // /YYYY/MM/DD/nx-s1-.../opinion-<slug> article links, most recent item 6 days
                // old at verification time. Titles are themselves literally prefixed
                // "Opinion: ..." -- caught by SubtopicKeywords.opinionSelfLabelKeywords'
                // "opinion:" entry (Tier A, review fix round 2), since the URL slug embeds
                // "opinion-<slug>" as one hyphenated segment
                // rather than a bare "opinion" path segment (see SubtopicClassifier's
                // genericOpinionMatch doc comment). Extracts fine via the existing #storytext
                // selector below -- same template as NPR's other sections.
                FeedEndpoint(url: URL(string: "https://feeds.npr.org/1057/rss.xml")!, defaultCategory: .us)
            ],
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: "#storytext",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours,
            // v1.3.3 fix A (reader-extraction-investigation.md §4, 4/23 sampled): `.bucketblock`
            // recirc modules ("Books We Love", "The Book Ahead") + repeated "Life Kit"
            // franchise-heading, appended mid/end-article -- confirmed live 2026-07-27. Real
            // prose still dominates every sampled article, but the widget's own heading+links
            // shouldn't leak into the story body regardless.
            junkSelectors: [".bucketblock"]
        ),
        SourceConfig(
            id: "bbc",
            name: "BBC News",
            feeds: [
                FeedEndpoint(url: URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!, defaultCategory: .world)
            ],
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: "article",
            excludeURLPatterns: ["/av/", "/videos/"],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "pbs",
            name: "PBS NewsHour",
            feeds: [
                FeedEndpoint(url: URL(string: "https://pbs.org/newshour/feeds/rss/headlines")!, defaultCategory: .us)
            ],
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: ".body-text",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "aljazeera",
            name: "Al Jazeera",
            feeds: [
                FeedEndpoint(url: URL(string: "https://aljazeera.com/xml/rss/all.xml")!, defaultCategory: .world)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".wysiwyg",
            excludeURLPatterns: ["/program/", "/video/", "/liveblog/"],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours,
            // v1.3.3 fix A (reader-extraction-investigation.md §4, 25/30 sampled): `.more-on`
            // "Recommended Stories" -- a bare heading label with no attached headline/image
            // content -- confirmed live 2026-07-27. Cosmetic (never displaces real text) but
            // still a stray heading that doesn't belong in the story body.
            junkSelectors: [".more-on"]
        ),
        SourceConfig(
            id: "propublica",
            name: "ProPublica",
            feeds: [
                FeedEndpoint(url: URL(string: "https://propublica.org/feeds/propublica/main")!, defaultCategory: .us)
            ],
            strategy: .feedFullText,
            weight: 1.0,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "fox",
            name: "Fox News",
            feeds: [
                FeedEndpoint(url: URL(string: "https://moxie.foxnews.com/google-publisher/latest.xml")!, defaultCategory: .us)
            ],
            strategy: .feedFullText,
            weight: 0.75,
            bodySelector: nil,
            excludeURLPatterns: ["/video/", "/category/"],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours
        ),
        SourceConfig(
            id: "nypost",
            name: "NY Post",
            feeds: [
                FeedEndpoint(url: URL(string: "https://nypost.com/feed/")!, defaultCategory: .us)
            ],
            strategy: .pageExtract,
            weight: 0.75,
            bodySelector: ".single__content",
            excludeURLPatterns: ["/betting/", "/shopping/"],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours,
            // v1.3.1 item 2: NY Post's feed carries pagesix.com/decider.com streaming-promo
            // listicles ("How to watch <show> on Hulu/Netflix/...") -- ads, not news. Their URL
            // slug sits under an ordinary /entertainment/ section (not /shopping/, confirmed
            // live 2026-07-27), so a title-prefix check catches them where excludeURLPatterns
            // can't.
            excludeTitlePrefixes: ["how to watch"],
            // v1.3.1 item 4: NY Post's newsletter-signup widget (confirmed live 2026-07-27,
            // e.g. nypost.com/2026/07/27/opinion/yes-mamdani-just-made-a-business-basher-his-
            // nyc-economic-development-czar/) renders a whole `.single__inline-module` subtree
            // -- a fake <h3> "heading" plus a promo <p> -- that a plain paragraph-text filter
            // alone can't fully catch.
            junkSelectors: [".inline-module"]
        ),
        SourceConfig(
            id: "politico",
            name: "Politico",
            feeds: [
                // v1.1 category/section reconciliation: Politico -> .us (place), + subtopic
                // politics (SubtopicClassifier.politico() defaults to .usPolitics).
                FeedEndpoint(url: URL(string: "https://rss.politico.com/politics-news.xml")!, defaultCategory: .us)
            ],
            strategy: .feedFullText,
            weight: 1.0,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "axios",
            name: "Axios",
            feeds: [
                FeedEndpoint(url: URL(string: "https://api.axios.com/feed/")!, defaultCategory: .us)
            ],
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours
        ),
        SourceConfig(
            id: "blockclub",
            name: "Block Club Chicago",
            feeds: [
                FeedEndpoint(url: URL(string: "https://blockclubchicago.org/feed/")!, defaultCategory: .chicago)
            ],
            strategy: .feedFullText,
            weight: 1.0,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "suntimes",
            name: "Chicago Sun-Times",
            feeds: [
                FeedEndpoint(url: URL(string: "https://chicago.suntimes.com/rss/index.xml")!, defaultCategory: .chicago)
            ],
            strategy: .feedFullText,
            weight: 1.0,
            bodySelector: nil,
            // v1.1: dear-abby and horoscopes are syndicated filler, not news -- never ingest
            // them (confirmed live 2026-07-27: chicago.suntimes.com/dear-abby/... is a real,
            // regularly-published URL segment on this feed).
            excludeURLPatterns: ["/dear-abby/", "/horoscopes/"],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours,
            // v1.4: Sun-Times + WBEZ's known editorial partnership -- corroboration-by-section.md
            // found 4 of Chicago's 5 threshold-0.35 "cross-source" clusters were exactly this
            // pair covering the identical story, not independent verification.
            marketGroups: ["chicago-print"]
        ),
        SourceConfig(
            id: "wbez",
            name: "WBEZ",
            feeds: [
                FeedEndpoint(url: URL(string: "https://wbez.org/rss/index.xml")!, defaultCategory: .chicago)
            ],
            strategy: .feedFullText,
            weight: 1.0,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours,
            marketGroups: ["chicago-print"]
        ),
        SourceConfig(
            id: "reader",
            name: "Chicago Reader",
            feeds: [
                FeedEndpoint(url: URL(string: "https://chicagoreader.com/feed/")!, defaultCategory: .chicago)
            ],
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: ".entry-content",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours,
            // v1.3.3 fix A (reader-extraction-investigation.md §2a/§3, 28/30 sampled): the
            // "More in X" / "Reader Recommends: Y" related-posts module (an <h4>, a tagline
            // <p>, and six unrelated <article data-post-id=...> cards) lives INSIDE
            // .entry-content, appended after the real story on every article's template --
            // confirmed live 2026-07-27. Its class is `below-content`/`wpnbha`, not `related`,
            // so the existing generic `.related` selector never matched it.
            junkSelectors: ["section.below-content"]
        ),
        SourceConfig(
            id: "abc7",
            name: "ABC7 Chicago",
            feeds: [
                FeedEndpoint(url: URL(string: "https://abc7chicago.com/feed/")!, defaultCategory: .chicago)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: "div[data-testid=prism-article-body]",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours,
            // v1.4 fix round 1 (Important 2): abc7 is BOTH a Chicago TV affiliate (with nbc5)
            // AND an ABC owned-and-operated station (with abcnews) -- `marketGroups` is now a
            // `Set`, so both memberships are represented directly instead of forcing a pick
            // between them (v1.3.3's single-`String?` shape flagged this as an open concern in
            // the v1.4 report; resolved here). Net effect: abc7+abcnews now correctly collapses
            // to 1 independent voice, and abc7's dual membership transitively bridges nbc5 and
            // abcnews together too (`StoryClusterer.independentGroups`'s connected-components
            // grouping) -- over-collapsing being the conservative, evidence-favored direction.
            marketGroups: ["chicago-tv", "abc"]
        ),
        SourceConfig(
            id: "nbc5",
            name: "NBC5 Chicago",
            feeds: [
                FeedEndpoint(url: URL(string: "https://nbcchicago.com/news/?rss=y")!, defaultCategory: .chicago)
            ],
            strategy: .pageExtract,
            weight: 0.75,
            bodySelector: ".article-content.rich-text",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours,
            // v1.3.3 fix A (reader-extraction-investigation.md §4, 12/30 sampled):
            // `.recirc-module` -- a topic-linked heading ("Weather", etc.) plus 1-2 unrelated
            // headline+image pairs injected mid-article -- confirmed live 2026-07-27.
            junkSelectors: [".recirc-module"],
            // v1.4 fix round 1 (Important 2): also an NBC affiliate, alongside chicago-tv (nbc5's
            // own duopoly partner is abc7, not nbcnews directly -- but see abc7's doc comment
            // above for the transitive bridge this creates).
            marketGroups: ["chicago-tv", "nbc"]
        ),

        // v1.3.1 item 7: six new U.S. sources (approved 2026-07-27, live-verified same
        // day). EXACT values per the spec's table -- see SourceCatalogTests for the sweep tests
        // pinning them down, and the v1.3.1 report for the per-source implementation notes.
        SourceConfig(
            id: "cbs",
            name: "CBS News",
            feeds: [
                FeedEndpoint(url: URL(string: "https://www.cbsnews.com/latest/rss/main")!, defaultCategory: .us)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".content__body",
            // Confirmed live 2026-07-27: this feed is heavily video-weighted (roughly half of a
            // sampled 30-item pull were /video/ pages, plus /live-updates/ continuously-updated
            // pages) -- neither has real article text under .content__body, so both would just
            // burn maxPerDay budget on guaranteed extraction failures.
            excludeURLPatterns: ["/video/", "/live-updates/"],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours
        ),
        SourceConfig(
            id: "nbcnews",
            name: "NBC News",
            feeds: [
                FeedEndpoint(url: URL(string: "https://feeds.nbcnews.com/nbcnews/public/news")!, defaultCategory: .us)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".article-body__content",
            // Confirmed live 2026-07-27: several video-only items per pull (/video/, /now/video/,
            // /nightly-news/video/ -- all caught by the single "/video/" substring).
            excludeURLPatterns: ["/video/"],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours,
            // v1.3.3 fix A (reader-extraction-investigation.md §4, 5/19 sampled):
            // `[data-testid=related]` "Related" widget -- one unrelated headline near the end
            // of shopping listicles -- confirmed live 2026-07-27.
            junkSelectors: ["[data-testid=related]"],
            // Implementation note (verification): one observed <link> pointed at the homepage
            // while <guid isPermaLink="true"> carried the real article URL -- see
            // FeedParser.applyGUIDAsURLPreference, applied in RefreshCoordinator whenever this
            // is true and the item's guid itself parses as an absolute http(s) URL.
            preferGUIDAsURL: true,
            // v1.4 fix round 1 (Important 2): shares the "nbc" voice with nbc5 (a Chicago NBC
            // affiliate) -- see nbc5's own doc comment for the transitive abc7-mediated bridge
            // this creates with abcnews/chicago-tv.
            marketGroups: ["nbc"]
        ),
        SourceConfig(
            id: "abcnews",
            name: "ABC News",
            feeds: [
                FeedEndpoint(url: URL(string: "https://abcnews.go.com/abcnews/topstories")!, defaultCategory: .us)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            // ABC's class names are hashed React output (confirmed live 2026-07-27, e.g.
            // `class="theme-e FITT_Article_main__body oBTii mrzah "`) -- match the stable
            // "FITT_Article_main__body" substring via a CSS attribute-contains selector, never
            // the full (unstable, build-hashed) class string.
            bodySelector: "[class*=FITT_Article_main__body]",
            excludeURLPatterns: ["/video/"],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours,
            // v1.3.3 fix A (reader-extraction-investigation.md §4, 16/16 sampled):
            // `[data-testid=prism-collection]` "Popular Reads" widget -- 3 unrelated
            // headline+image pairs injected mid-article -- confirmed live 2026-07-27.
            junkSelectors: ["[data-testid=prism-collection]"],
            // v1.4 fix round 1 (Important 2): shares the "abc" voice with abc7 -- see abc7's own
            // doc comment for the transitive bridge this creates with nbc5/chicago-tv.
            marketGroups: ["abc"]
        ),
        // v1.11.1: The Hill REMOVED, not just disabled -- same "cannot bypass a bot check"
        // principle Newsweek was already rejected on (see testRejectedSourcesAreNotInTheCatalog).
        // Device diagnostics (2026-08-02) showed thehill fetching 0 articles/day while
        // filtering ~134/day -- every single article-page fetch was gate-rejected with "only 0
        // paragraph blocks". Live-verified same day: thehill.com/?p=... article URLs return HTTP
        // 403 with a PerimeterX bot challenge ("Access to this page has been denied", px-captcha
        // marker) -- the page HTML this source's .pageExtract strategy needs was never reachable.
        // Both feeds (thehill.com/feed/, thehill.com/opinion/feed/) were also independently
        // verified excerpt-only (~300-char <description>, no <content:encoded>), so switching
        // this source to .feedFullText isn't an option either -- there is no legitimate path to
        // this source's full article text. Stored thehill articles already on a device simply
        // age out via the existing 7-day retention prune; every sourceID -> SourceConfig lookup
        // in this app already resolves an unknown/orphaned sourceID to a safe default rather than
        // crashing (see LeadScorer.score/StackRanker.score's `config?.weight ?? 1.0`-style
        // fallbacks, already exercised by StackRankerTests
        // .test_tieredDecay_unknownSourceDefaultsTo12HourHalfLife and ReadingDietTests
        // .testUnknownSourceID_countedInTotalAndTopSources_excludedFromByLean).
        SourceConfig(
            id: "examiner",
            name: "Washington Examiner",
            feeds: [
                FeedEndpoint(url: URL(string: "https://www.washingtonexaminer.com/feed")!, defaultCategory: .us)
            ],
            // Full text in content:encoded -- feedFullText, no page fetch (confirmed live
            // 2026-07-27).
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "reason",
            name: "Reason",
            feeds: [
                FeedEndpoint(url: URL(string: "https://reason.com/latest/feed/")!, defaultCategory: .us)
            ],
            // Full text in content:encoded -- feedFullText, no page fetch (confirmed live
            // 2026-07-27; 30 of 48 sampled items also carried inline images).
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: ".entry-content",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),

        // v1.7 §3: four new sources (approved 2026-07-29, live-verified same day). The
        // Substack pair (Bulwark, Persuasion) was deferred, not added. Two rejections,
        // deliberately NOT added: National Review (Cloudflare JS challenge on every article page
        // -- no text reachable without defeating a bot check, out of bounds per this project's
        // standing rule; also already rejected pre-v1.7, not revisited) and Project Syndicate
        // (teaser-only, hard paywall -- no full article text reachable at all).
        SourceConfig(
            id: "conversation",
            name: "The Conversation",
            feeds: [
                FeedEndpoint(url: URL(string: "https://theconversation.com/us/articles.atom")!, defaultCategory: .us)
            ],
            // Live-verified 2026-07-29: Atom feed, real article links, `[itemprop=articleBody]`
            // matches exactly once on a live article with 19 clean paragraphs (no republishing
            // boilerplate/author-bio junk inside the container -- no junkSelectors needed).
            //
            // Republishing license (spec: "record the EXACT Creative Commons variant"): fetched
            // theconversation.com/us/republishing-guidelines live 2026-07-29. Exact quoted text:
            // "we... publish all our work under a Creative Commons — Attribution/No Derivatives
            // license" linking to http://creativecommons.org/licenses/by-nd/4.0/ -- i.e. CC
            // BY-ND 4.0, confirming the spec's own guess.
            //
            // Review fix round 2 (2026-07-29): corrected. This comment previously asserted the
            // license's republishing conditions "don't bind this use" because the app has "no
            // re-publishing/re-distribution to others" -- a legal conclusion the spec never
            // asked for, and one that doesn't square with this project's own recorded decision
            // (2026-07-27) that Broadsheet may be distributed to users beyond a single device.
            // Stated factually: the license's conditions require crediting the author and their
            // institution, and including The Conversation's page-view tracking pixel, on any
            // republication.
            //
            // v1.8 (decision recorded 2026-07-29): add the credit line rather than drop the
            // source or accept the risk as-is. `requiresAttribution: true` below is what turns
            // that on -- ArticleGate now refuses to ingest an article from this source if
            // extraction found no author or institution at all (ContentExtractor's schema.org
            // byline reader, live-verified against this exact source), and ArticleView renders
            // the required credit line on this source's article pages. The pixel is deliberately
            // NOT implemented -- see the code comment next to ArticleView's credit line for why.
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: "[itemprop=articleBody]",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours,
            requiresAttribution: true
        ),
        SourceConfig(
            id: "amcon",
            name: "The American Conservative",
            feeds: [
                FeedEndpoint(url: URL(string: "https://www.theamericanconservative.com/feed/")!, defaultCategory: .us)
            ],
            // Full text in content:encoded -- feedFullText, no page fetch (confirmed live
            // 2026-07-29, WordPress `<p class="wp-block-paragraph">` markup).
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "vox",
            name: "Vox",
            feeds: [
                FeedEndpoint(url: URL(string: "https://www.vox.com/rss/index.xml")!, defaultCategory: .us)
            ],
            // Live-verified 2026-07-29 against two ordinary articles (not the spec table's
            // literal `.duet--article--article-body-component`): that class turned out to be a
            // PER-PARAGRAPH wrapper -- 6-7 sibling elements each containing exactly 1 paragraph,
            // not one container for the whole body -- so `matches.first()` (ContentExtractor's
            // single-container contract) would only ever capture the first paragraph, well under
            // the 3-paragraph floor, and silently fall through to the generic fallback finder on
            // every single article. The real single-container wrapper, confirmed on both test
            // articles, is `.duet--layout--entry-body` (Vox's "duet" design-system naming
            // convention, not a build-hashed class -- same stability class as thehill's
            // `.article__text`). Corrected here rather than transcribing the spec table's
            // unverified value, per this project's "don't guess a selector" standing rule.
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".duet--layout--entry-body",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "slate",
            name: "Slate",
            feeds: [
                FeedEndpoint(url: URL(string: "https://slate.com/feeds/all.rss")!, defaultCategory: .us)
            ],
            // Body selector was NOT pinned during v1.7 verification (spec, explicitly flagged
            // "don't guess") -- identified live 2026-07-29 from a real article
            // (slate.com/news-and-politics/.../supreme-court-news-scotus-reform-quick-fix.html):
            // `.article__content` (a `<div itemprop="mainEntityOfPage">`, Slate's own schema.org
            // marker for the real story content) matches exactly once and contains all 11 real
            // paragraphs. It sits nested one level inside a wider `<section class="article__body">`
            // that also wraps a left-rail share-sidebar with no paragraphs of its own -- either
            // selector captures the same content on this article, but `.article__content`'s
            // itemprop marker is the more precise, purpose-built target. See
            // BroadsheetTests/Fixtures/page-slate.html for the fixture this was pinned against.
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".article__content",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        )
    ]

    /// Final review batch (Minor #6): kicker-scoped display name for a sourceID, used by
    /// `ArticleKicker` (and so, transitively, by every kicker rendered inside `DailyStackView`
    /// via `ArticleRowView`, plus `ArticleView`'s reader header) instead of the raw
    /// `sourceID.uppercased()` it used before. Settings/DebugView/SourceHealthView keep showing
    /// each source's full official `name` unchanged -- only the two Chicago-qualified names
    /// below read awkwardly once concatenated straight from `sourceID` ("SUNTIMES",
    /// "BLOCKCLUB"), matching the spec's own kicker example (`SUN-TIMES · CRIME & SAFETY`) --
    /// every other source's `sourceID.uppercased()` is already a clean, recognizable kicker
    /// label, so this stays a small override map rather than a blanket switch to `name`
    /// (which would needlessly lengthen kickers like `guardian` -> "THE GUARDIAN").
    private static let kickerDisplayNameOverrides: [String: String] = [
        "suntimes": "Sun-Times",
        "blockclub": "Block Club"
    ]

    static func kickerDisplayName(for sourceID: String) -> String {
        (kickerDisplayNameOverrides[sourceID] ?? sourceID).uppercased()
    }

    /// v1.4 fix round 1: sourceID -> marketGroups SET for every catalog source that has one,
    /// ready to hand straight to `StoryClusterer.cluster(items:marketGroup:...)`/
    /// `independentGroups(sourceIDs:marketGroups:)`. Sources with no group (the overwhelming
    /// majority) are simply absent, matching those functions' "missing/empty set = independent"
    /// convention.
    static let marketGroups: [String: Set<String>] = Dictionary(
        uniqueKeysWithValues: all.compactMap { config in
            config.marketGroups.isEmpty ? nil : (config.id, config.marketGroups)
        }
    )
}
