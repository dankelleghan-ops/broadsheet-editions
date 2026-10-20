import Foundation

enum SourceCatalog {
    // v1.1 tiered recency decay (Tier-1 ride-along #4): fast half-life for high-volume/
    // breaking-news sources, standard for the v1 default, slow for sources that publish less
    // often but whose stories stay relevant longer (investigative/alt-weekly). See
    // StackRanker, which reads `decayHalfLifeHours` per source instead of a global 12h.
    private static let fastDecayHours = 3.5
    private static let standardDecayHours = 12.0
    private static let slowDecayHours = 24.0

    // Sections (topic feeds, approved by Daniel 2026-10-15). A TOPIC FEED is a feed that carries one topic from an outlet
    // that already is (or newly joins) the catalog: the Guardian's business feed, NPR's tech feed, the Sun-Times' Bears feed.
    // Every story it brings in is filed under that topic (`FeedEndpoint.topicHint`) and has its own daily allowance
    // (a quarter of the reader's "stories per source per day", `ArticleStore.topicAllowance`) so it never eats into the outlet's
    // main-news budget. Topic feeds are listed AFTER the outlet's
    // main feeds: a story that appears in both is taken through the main feed (the first feed to see a guid wins, as ever),
    // and the edition path's stand-in endpoint for a story (`ArticleStore.insertEditionRow`) stays the first main feed.
    //
    // The hints are `Topic` raw values. This file is vendored into the edition builder, which has no `Topic` type, so they are
    // plain strings here; SourceCatalogTests pins every hint in the catalog to a real `Topic`.
    private enum Hint {
        static let business = "business", sports = "sports", tech = "tech", scienceHealth = "scienceHealth"
        static let climate = "climate", arts = "arts", books = "books", food = "food", travel = "travel"
        static let style = "style", realEstate = "realEstate", obituaries = "obituaries"
    }

    /// One topic feed: the feed's URL, the place its stories default to (the same `defaultCategory` a main feed has), and the topic
    /// every story belongs to. It declares NO `maxPerDay` of its own: the edition builder takes the default 10 new stories per run
    /// from it (`FeedEndpoint.topicMaxPerDay`), and the app's daily allowance follows the reader's "stories per source per day"
    /// setting (a quarter of it, never below 2; see `ArticleStore.topicAllowance`). A `maxPerDay` on a topic feed would be a
    /// CEILING on both, so a feed that needs a tighter limit than the setting gives declares one.
    private static func topicFeed(_ urlString: String, _ place: ArticleCategory, _ topic: String) -> FeedEndpoint {
        FeedEndpoint(url: URL(string: urlString)!, defaultCategory: place, topicHint: topic)
    }

    static let all: [SourceConfig] = [
        SourceConfig(
            id: "guardian",
            name: "The Guardian",
            feeds: [
                FeedEndpoint(url: URL(string: "https://theguardian.com/world/rss")!, defaultCategory: .world),
                FeedEndpoint(url: URL(string: "https://theguardian.com/us-news/rss")!, defaultCategory: .us),
                // Sections: the Guardian's own section feeds (live-verified 2026-10-15/18; the Guardian's `us/` editions where the
                // U.S. edition exists, the global feed where it does not). Items carry /gallery/, /live/, /video/, /audio/ and
                // /thefilter/ pages: `ArticleGate.addressRejectionReason` drops those, and its 7-day age rule drops the travel
                // feed's 2023-24 guides.
                topicFeed("https://www.theguardian.com/us/business/rss", .us, Hint.business),
                topicFeed("https://www.theguardian.com/us/sport/rss", .us, Hint.sports),
                topicFeed("https://www.theguardian.com/us/technology/rss", .us, Hint.tech),
                topicFeed("https://www.theguardian.com/science/rss", .world, Hint.scienceHealth),
                topicFeed("https://www.theguardian.com/environment/climate-crisis/rss", .world, Hint.climate),
                topicFeed("https://www.theguardian.com/us/culture/rss", .us, Hint.arts),
                topicFeed("https://www.theguardian.com/us/film/rss", .world, Hint.arts),
                topicFeed("https://www.theguardian.com/music/rss", .world, Hint.arts),
                topicFeed("https://www.theguardian.com/books/rss", .world, Hint.books),
                topicFeed("https://www.theguardian.com/food/rss", .world, Hint.food),
                topicFeed("https://www.theguardian.com/us/travel/rss", .world, Hint.travel),
                topicFeed("https://www.theguardian.com/fashion/rss", .world, Hint.style),
                topicFeed("https://www.theguardian.com/tone/obituaries/rss", .world, Hint.obituaries)
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
                FeedEndpoint(url: URL(string: "https://feeds.npr.org/1057/rss.xml")!, defaultCategory: .us),
                // Sections: NPR's topic feeds (1006 Business, 1019 Technology, 1128 Health, 1007 Science, 1167 Climate,
                // 1008 Arts & Life, 1032 Books, 1062 Obituaries). They carry audio-only blurbs next to real stories, so
                // `ArticleGate.topicFeedMinimumWords` requires 150 words of body from NPR's topic feeds.
                topicFeed("https://feeds.npr.org/1006/rss.xml", .us, Hint.business),
                topicFeed("https://feeds.npr.org/1019/rss.xml", .us, Hint.tech),
                topicFeed("https://feeds.npr.org/1128/rss.xml", .us, Hint.scienceHealth),
                topicFeed("https://feeds.npr.org/1007/rss.xml", .us, Hint.scienceHealth),
                topicFeed("https://feeds.npr.org/1167/rss.xml", .us, Hint.climate),
                topicFeed("https://feeds.npr.org/1008/rss.xml", .us, Hint.arts),
                topicFeed("https://feeds.npr.org/1032/rss.xml", .us, Hint.books),
                topicFeed("https://feeds.npr.org/1062/rss.xml", .us, Hint.obituaries)
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
                FeedEndpoint(url: URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!, defaultCategory: .world),
                // Sections: BBC News' business, technology, health, science & environment and entertainment & arts feeds, plus
                // bbc.com's Culture and Travel feeds.
                topicFeed("https://feeds.bbci.co.uk/news/business/rss.xml", .world, Hint.business),
                topicFeed("https://feeds.bbci.co.uk/news/technology/rss.xml", .world, Hint.tech),
                topicFeed("https://feeds.bbci.co.uk/news/health/rss.xml", .world, Hint.scienceHealth),
                topicFeed("https://feeds.bbci.co.uk/news/science_and_environment/rss.xml", .world, Hint.scienceHealth),
                topicFeed("https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml", .world, Hint.arts),
                topicFeed("https://www.bbc.com/culture/feed.rss", .world, Hint.arts),
                topicFeed("https://www.bbc.com/travel/feed.rss", .world, Hint.travel)
            ],
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: "article",
            excludeURLPatterns: ["/av/", "/videos/"],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours,
            // 2026-10-12: the `article` container also holds two recirculation blocks after the
            // last paragraph, found in the edition's stored bodies and confirmed on pages fetched
            // with the compiler's own user agent. (1) `[data-testid=topic-list]`: the "Related
            // topics" heading (all 57 BBC bodies; the topic links are list items and never became
            // blocks, so only the heading leaked). (2) `[data-block=promoList]`: other stories'
            // headlines and photos under "More on this story" (40 bodies) and the "BBC Africa
            // podcasts" module (4 bodies) -- BBC wraps both in the same promoList block. A third
            // block type, `[data-block=links]` ("More stories from South Africa:"), is deliberately
            // NOT stripped here; it needs its own look.
            // (3) `figcaption .visually-hidden`: BBC puts a screen-reader label inside every figcaption,
            // `<span class="visually-hidden ...">Image caption, </span>` ("Figure caption, " on video
            // figures), so 92 of 92 BBC captions in the 2026-10-12 edition began "Image caption, Trump
            // announced ...". Scoped to figcaptions, so no other hidden text is touched; the credit label
            // ("Image source, ") sits OUTSIDE the figcaption and is not read at all.
            junkSelectors: ["[data-testid=topic-list]", "[data-block=promoList]", "figcaption .visually-hidden"]
        ),
        SourceConfig(
            id: "pbs",
            name: "PBS NewsHour",
            feeds: [
                FeedEndpoint(url: URL(string: "https://pbs.org/newshour/feeds/rss/headlines")!, defaultCategory: .us),
                // Sections: PBS NewsHour's economy, health and science feeds.
                topicFeed("https://www.pbs.org/newshour/feeds/rss/economy", .us, Hint.business),
                topicFeed("https://www.pbs.org/newshour/feeds/rss/health", .us, Hint.scienceHealth),
                topicFeed("https://www.pbs.org/newshour/feeds/rss/science", .us, Hint.scienceHealth)
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
                FeedEndpoint(url: URL(string: "https://moxie.foxnews.com/google-publisher/latest.xml")!, defaultCategory: .us),
                // Sections: Fox News Sports and Fox Business. (Fox travel was considered and left out on 2026-10-18.)
                topicFeed("https://moxie.foxnews.com/google-publisher/sports.xml", .us, Hint.sports),
                topicFeed("https://moxie.foxbusiness.com/google-publisher/latest.xml", .us, Hint.business)
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
                FeedEndpoint(url: URL(string: "https://nypost.com/feed/")!, defaultCategory: .us),
                // Sections: NY Post's business, sports, travel, real-estate and fashion-and-beauty feeds.
                topicFeed("https://nypost.com/business/feed/", .us, Hint.business),
                topicFeed("https://nypost.com/sports/feed/", .us, Hint.sports),
                topicFeed("https://nypost.com/travel/feed/", .us, Hint.travel),
                topicFeed("https://nypost.com/real-estate/feed/", .us, Hint.realEstate),
                topicFeed("https://nypost.com/fashion-and-beauty/feed/", .us, Hint.style)
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
            //
            // 2026-10-12: the feed also carries decider.com and pagesix.com pages. Those have no
            // `.single__content`, so the extractor falls back to the largest paragraph cluster, which
            // keeps the page's own furniture: `.sharedaddy` (the "Share this:" bar),
            // `.google-preferred-sources` (the "See more of our coverage in your search results"
            // button text), `#reelgood-inline` (the "Where to Stream:" widget, with streaming-service
            // logos) and `.more-on` (a "More On:" list of other stories' headlines). 12 of 24 blocks
            // in a typical Decider recap were these. On nypost.com pages
            // `h2.wp-block-heading:has(a[href*=why-trust-post-wanted])` removes only the "Why you
            // should trust 'Post Wanted'" disclosure heading (it links to the trust page); the
            // paragraph under it, the article's byline, stays.
            junkSelectors: [".inline-module", "#reelgood-inline", ".more-on", ".sharedaddy", ".google-preferred-sources",
                            "h2.wp-block-heading:has(a[href*=why-trust-post-wanted])"]
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
                FeedEndpoint(url: URL(string: "https://blockclubchicago.org/feed/")!, defaultCategory: .chicago),
                // Sections: Block Club's restaurants-and-bars category.
                topicFeed("https://blockclubchicago.org/category/restaurants-bars/feed/", .chicago, Hint.food)
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
                FeedEndpoint(url: URL(string: "https://chicago.suntimes.com/rss/index.xml")!, defaultCategory: .chicago),
                // Sections: the Sun-Times' sports feed and its four team feeds (Bears, White Sox, Bulls, Blackhawks; the team
                // feeds repeat much of the sports feed, and a guid already taken is skipped), then arts-and-culture, food-drink,
                // real-estate and obituaries. All live-verified 2026-10-18. The five sports feeds share ONE sports allowance
                // per day (stories are counted per outlet and topic, see `ArticleStore.topicAllowance`).
                topicFeed("https://chicago.suntimes.com/rss/sports/index.xml", .chicago, Hint.sports),
                topicFeed("https://chicago.suntimes.com/rss/bears/index.xml", .chicago, Hint.sports),
                topicFeed("https://chicago.suntimes.com/rss/white-sox/index.xml", .chicago, Hint.sports),
                topicFeed("https://chicago.suntimes.com/rss/bulls/index.xml", .chicago, Hint.sports),
                topicFeed("https://chicago.suntimes.com/rss/blackhawks/index.xml", .chicago, Hint.sports),
                topicFeed("https://chicago.suntimes.com/rss/arts-and-culture/index.xml", .chicago, Hint.arts),
                topicFeed("https://chicago.suntimes.com/rss/food-drink/index.xml", .chicago, Hint.food),
                topicFeed("https://chicago.suntimes.com/rss/real-estate/index.xml", .chicago, Hint.realEstate),
                topicFeed("https://chicago.suntimes.com/rss/obituaries/index.xml", .chicago, Hint.obituaries)
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
                FeedEndpoint(url: URL(string: "https://chicagoreader.com/feed/")!, defaultCategory: .chicago),
                // Sections: the Reader's music, film-and-TV and food categories.
                topicFeed("https://chicagoreader.com/category/music/feed/", .chicago, Hint.arts),
                topicFeed("https://chicagoreader.com/category/film-tv/feed/", .chicago, Hint.arts),
                topicFeed("https://chicagoreader.com/category/food/feed/", .chicago, Hint.food)
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
            // 2026-10-12: the same Prism "collection" widget abcnews strips (see below). In some ABC7
            // page responses it sits INSIDE the article body, between paragraphs, as
            // `<section class="MobileContentPromo" data-testid="prism-collection">`: a "Top Stories"
            // <h2> plus 3 cards, each a thumbnail and the <h2> headline of an unrelated story. 19 of
            // the 34 ABC7 articles in that day's edition carried it. The sidebar and footer
            // collections on the same pages are outside the body container and unaffected.
            //
            // Also 2026-10-12: `h3:has(a[href*=/watch/live/])` removes an editor-embedded heading
            // that promotes the station's 24/7 live stream ("ABC7 Chicago is now streaming 24/7.
            // Click here to watch"), an <h3> wrapping a link to /watch/live/ in the middle of the
            // text (8 stored bodies). Only a heading that is itself a link to the live-stream page
            // matches; other headings and links are untouched.
            junkSelectors: ["[data-testid=prism-collection]", "h3:has(a[href*=/watch/live/])"],
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
                // The feed's <pubDate>/<updateDate> are written `Sun, Oct 11 2026 04:04:04 PM` with NO zone
                // (verified 2026-10-11 against four article pages' JSON-LD `datePublished`, e.g.
                // `2026-10-11T16:04:04-05:00`): Chicago local time. Until this was declared, every NBC 5
                // item parsed as undated and was stamped with the compile time instead.
                FeedEndpoint(url: URL(string: "https://nbcchicago.com/news/?rss=y")!, defaultCategory: .chicago,
                             zonelessDatesTimeZone: TimeZone(identifier: "America/Chicago"))
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
                FeedEndpoint(url: URL(string: "https://www.cbsnews.com/latest/rss/main")!, defaultCategory: .us),
                // Sections: CBS MoneyWatch.
                topicFeed("https://www.cbsnews.com/latest/rss/moneywatch", .us, Hint.business)
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
            decayHalfLifeHours: standardDecayHours,
            // 2026-10-12: Vox drops a "Related" module (an <h3> plus a one-link list pointing at
            // another Vox story, `.duet--article--related`) between paragraphs of the body; 4 stored
            // bodies carried the stray "Related" heading. The class uses Vox's stable "duet--"
            // design-system naming, like the body selector above, not a build-hashed name.
            junkSelectors: [".duet--article--related"]
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
        ),

        // Sections: 13 new outlets, approved by Daniel 2026-10-15 and live-verified 2026-10-18 (free, full text reachable, no bot
        // wall; CNBC and Redfin turned a curl user agent away on 2026-10-15 but serve the compiler's own honest user agent).
        // A 14th, Science News, was approved and then LEFT OUT on 2026-10-18: its article pages are metered (Zephr). Fetched one at a
        // time with no cookies every page is whole, but a session that has read two articles gets the third cut to a few
        // paragraphs behind a sign-in form (measured: 8 of 10 articles in one compile run). Fetching without the session cookie to
        // dodge the meter would be bypassing a paywall, so the outlet is not in the catalog (SourceCatalogTests pins that).
        // Each one carries TOPIC feeds only (one `FeedEndpoint.topicHint` per feed), so none of them spends a source's main daily
        // cap; they have their own daily allowance per feed topic (a quarter of the reader's per-source setting). KFF Health News, Grist, Lit Hub, Chicago Review of Books,
        // Eater and Redfin put the full article in the feed (feedFullText, no page fetch); the rest are page-extract with a
        // body selector read off real article pages (CNBC, ESPN, TechCrunch, Ars Technica, Afar, Chicago YIMBY and Urbanize:
        // Urbanize's feed carries the article only in <description>, which the feed parser does not treat as full text).
        SourceConfig(
            id: "cnbc",
            name: "CNBC",
            feeds: [
                topicFeed("https://www.cnbc.com/id/10001147/device/rss/rss.html", .us, Hint.business),
                topicFeed("https://www.cnbc.com/id/10000664/device/rss/rss.html", .us, Hint.business)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".ArticleBody-articleBody",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours,
            // Live 2026-10-18: every CNBC body opened with a lone "In this article" paragraph, the label of the stock-quote
            // box (`.RelatedQuotes-relatedQuotes`) that sits inside the article body.
            junkSelectors: [".RelatedQuotes-relatedQuotes"]
        ),
        SourceConfig(
            id: "espn",
            name: "ESPN",
            feeds: [
                topicFeed("https://www.espn.com/espn/rss/news", .us, Hint.sports)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".article-body",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: fastDecayHours,
            // Live 2026-10-18: `.article-body` opens with the byline block (`.article-meta`: the author's 40-pixel headshot)
            // and carries the "content reactions" widget (a check-mark icon image); both came out as stray image blocks.
            junkSelectors: [".article-meta", ".content-reactions"]
        ),
        SourceConfig(
            id: "techcrunch",
            name: "TechCrunch",
            feeds: [
                topicFeed("https://techcrunch.com/feed/", .us, Hint.tech)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".wp-block-post-content",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "arstechnica",
            name: "Ars Technica",
            feeds: [
                topicFeed("https://feeds.arstechnica.com/arstechnica/index", .us, Hint.tech)
            ],
            strategy: .pageExtract,
            weight: 1.0,
            bodySelector: ".article-content",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "kffhealthnews",
            name: "KFF Health News",
            feeds: [
                topicFeed("https://kffhealthnews.org/feed/", .us, Hint.scienceHealth)
            ],
            strategy: .feedFullText,
            weight: 1.0,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "grist",
            name: "Grist",
            feeds: [
                topicFeed("https://grist.org/feed/", .us, Hint.climate)
            ],
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "lithub",
            name: "Lit Hub",
            feeds: [
                topicFeed("https://lithub.com/feed/", .us, Hint.books)
            ],
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "chireviewofbooks",
            name: "Chicago Review of Books",
            feeds: [
                // Most of its reviews are of national books and authors, so its stories default to U.S., not Chicago.
                topicFeed("https://chireviewofbooks.com/feed/", .us, Hint.books)
            ],
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "eater",
            name: "Eater",
            feeds: [
                topicFeed("https://www.eater.com/rss/index.xml", .us, Hint.food),
                topicFeed("https://chicago.eater.com/rss/index.xml", .chicago, Hint.food)
            ],
            strategy: .feedFullText,
            weight: 0.85,
            bodySelector: nil,
            // Eater's feed carries affiliate "add-to-cart" shopping posts (live 2026-10-18: "The Best Gifts for Martini Lovers");
            // `ArticleGate.addressRejectionReason` drops them (/add-to-cart/), for every outlet.
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "afar",
            name: "Afar",
            feeds: [
                topicFeed("https://www.afar.com/index.rss", .us, Hint.travel)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".article-body",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
        ),
        SourceConfig(
            id: "chicagoyimby",
            name: "Chicago YIMBY",
            feeds: [
                topicFeed("https://chicagoyimby.com/feed", .chicago, Hint.realEstate)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".entry-content",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours,
            // Live 2026-10-18: every YIMBY article ends with a paragraph of newsletter / social links ("Subscribe to YIMBY's
            // daily e-mail ... Follow YIMBYgram ...") plus a "Make YIMBY preferred on Google" badge image. The newsletter link
            // (eepurl.com) identifies the paragraph.
            junkSelectors: ["p:has(a[href*=eepurl.com])"]
        ),
        SourceConfig(
            id: "urbanize",
            name: "Urbanize Chicago",
            feeds: [
                topicFeed("https://chicago.urbanize.city/rss.xml", .chicago, Hint.realEstate)
            ],
            strategy: .pageExtract,
            weight: 0.85,
            bodySelector: ".article-body",
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: standardDecayHours
        ),
        SourceConfig(
            id: "redfin",
            name: "Redfin News",
            feeds: [
                topicFeed("https://www.redfin.com/news/feed/", .us, Hint.realEstate)
            ],
            strategy: .feedFullText,
            weight: 0.75,
            bodySelector: nil,
            excludeURLPatterns: [],
            maxPerDay: 40,
            decayHalfLifeHours: slowDecayHours
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
        "blockclub": "Block Club",
        // Sections: the new outlets whose raw id runs words together ("ARSTECHNICA", "KFFHEALTHNEWS"). Kept to 12 characters or
        // fewer, the length of "CONVERSATION", the longest kicker label in the catalog: a longer label clips in a brief row at the
        // biggest text sizes (v1.9.1; BriefRowSourceClippingTests measures the longest). So "KFF HEALTH", "CHI. REVIEW" (Chicago
        // Review of Books) and "YIMBY" (Chicago YIMBY) are short forms.
        "arstechnica": "Ars Technica",
        "kffhealthnews": "KFF Health",
        "lithub": "Lit Hub",
        "chireviewofbooks": "Chi. Review",
        "chicagoyimby": "YIMBY"
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
