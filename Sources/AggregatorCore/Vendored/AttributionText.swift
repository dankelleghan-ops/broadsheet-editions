import Foundation

/// v1.8 (spec item 2): builds the licence-required credit line rendered on a
/// `requiresAttribution` source's article page (`ArticleView`), below the headline/deck --
/// `by <author>, <institution> — from The Conversation (CC BY-ND 4.0)`, degrading gracefully
/// when only one of `author`/`institution` is known.
///
/// This is DISPLAY-only. `Article.author`/`.authorInstitution` are populated by
/// `ContentExtractor`/`ArticleStore` for every source generically (spec item 1 -- "the fields
/// are generic and cost nothing"); only `ArticleView` calls this function, and only when
/// `SourceConfig.requiresAttribution` is true for that article's source (see that flag's doc
/// comment in `CoreTypes.swift` for why it's a per-source flag rather than a hardcoded
/// `sourceID == "conversation"` check -- storing is not the same as displaying, and the other
/// 25+ sources must render exactly as they did before this release).
///
/// The trailing "from The Conversation (CC BY-ND 4.0)" is a FIXED literal here, not a parameter,
/// because exactly one source requires attribution as of this release (pinned by
/// `SourceCatalogTests.testOnlyConversationRequiresAttribution`). If a second
/// `requiresAttribution` source is ever added with a different name/licence, this must be
/// generalized to take those as parameters instead of assuming The Conversation's own text --
/// flagging that now rather than guessing at a templating shape nothing yet needs.
///
/// ON THE LICENCE'S OTHER CONDITION -- THE PAGE-VIEW TRACKING PIXEL: the tracking pixel is not
/// fetched; the visible credit line satisfies the attribution requirement. Broadsheet is an
/// offline reader with no analytics of any kind, so the counter pixel would be the only network
/// callback anywhere in the reading path and would report reading activity to a third party --
/// at odds with the app's offline-first, private-reading design. It also cannot function as
/// intended here regardless: live inspection of a real article page (2026-07-29) shows the
/// pixel fires via a `<script data-counter="...">` tag that loads `content_tracker_hook.js`
/// and only THEN calls the counter URL -- Broadsheet's extraction is pure HTML parsing with no
/// JavaScript execution and no live WebView anywhere in the reading path, so that script could
/// never run even if it survived extraction (which it doesn't -- ContentExtractor only ever
/// emits paragraph/heading/image `BodyBlock`s, never `<script>` content). Recorded here once,
/// as a considered and revisitable choice (2026-07-29).
enum AttributionText {
    static func creditLine(author: String?, institution: String?) -> String? {
        let byline: String
        switch (author, institution) {
        case let (author?, institution?):
            byline = "by \(author), \(institution)"
        case let (author?, nil):
            byline = "by \(author)"
        case let (nil, institution?):
            byline = institution
        case (nil, nil):
            return nil
        }
        return "\(byline) — from The Conversation (CC BY-ND 4.0)"
    }
}
