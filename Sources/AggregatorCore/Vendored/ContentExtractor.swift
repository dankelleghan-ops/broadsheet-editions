import Foundation
import SwiftSoup

final class ContentExtractor {

    func extract(fromFeedHTML html: String, item: FeedItem) throws -> ExtractedArticle {
        let doc = try SwiftSoup.parseBodyFragment(html)
        // v1.8: feedFullText sources never fetch the live article page at all, so the feed's
        // own byline (Atom <author><name> / RSS <dc:creator>, see FeedItem.author) is the ONLY
        // possible source here -- not a fallback-after-a-failed-attempt the way it is in
        // `extract(fromPageHTML:...)` below, just the one source available.
        let feedByline = item.author.map(Self.splitFeedByline)
        guard let body = doc.body() else {
            return ExtractedArticle(title: item.title, byline: nil, bodyBlocks: [], heroImageURL: nil,
                                     allImageURLs: [], author: feedByline?.author, authorInstitution: feedByline?.institution,
                                     url: item.url)
        }
        let blocks = try Self.blocks(from: body, baseURL: item.url)
        return Self.buildArticle(title: item.title, blocks: blocks, ogImageURL: nil,
                                  author: feedByline?.author, authorInstitution: feedByline?.institution, url: item.url)
    }

    // MARK: - Block extraction (direct children) -- used only by feed-HTML fragments, which
    // are already a flat sequence of content nodes (no wrapping structure to walk through).

    fileprivate static func blocks(from container: Element, baseURL: URL) throws -> [BodyBlock] {
        var result: [BodyBlock] = []
        for node in container.children().array() {
            switch node.tagName().lowercased() {
            case "p":
                try appendParagraphOrAttachCaption(node, to: &result)
            case "h1", "h2", "h3", "h4":
                let text = try plainText(node)
                if !text.isEmpty, !isPromoJunkText(text, in: node) {
                    result.append(BodyBlock(kind: .heading, text: text, imageURLString: nil, caption: nil, credit: nil))
                }
            case "figure":
                if let block = imageBlock(fromFigure: node, baseURL: baseURL) {
                    result.append(block)
                }
            case "img":
                if let block = imageBlock(fromImg: node, baseURL: baseURL) {
                    result.append(block)
                }
            case "div":
                // v1.3.1 item 7 (Reason): images can arrive wrapped in a direct-child <div>
                // rather than a bare <img> or <figure> -- confirmed live 2026-07-27 via
                // reason.com/latest/feed/, e.g. <div class="img-wrap"><picture>...<img/></picture>
                // </div>. An unhandled div is otherwise silently skipped (unchanged for every
                // other feedFullText source); this only ever peeks for a nested <img> and adds
                // its image block, never touching paragraph extraction.
                if let imgMatches = try? node.select("img"), let img = imgMatches.first(),
                   let block = imageBlock(fromImg: img, baseURL: baseURL) {
                    result.append(block)
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Block extraction (descendants, document order) -- used by page extraction. Real
    // sites (Guardian #maincontent, BBC article, NPR #storytext) nest paragraphs and images in
    // wrapper divs at arbitrary depth; walking only direct children misses all of them.

    fileprivate static func blocksDescendant(from container: Element, baseURL: URL) throws -> [BodyBlock] {
        guard let matches = try? container.select("p, h2, h3, h4, figure, img") else { return [] }
        var result: [BodyBlock] = []
        for node in matches.array() {
            let tag = node.tagName().lowercased()
            // A <figure> already produces exactly one image block via imageBlock(fromFigure:),
            // which reaches in and pulls its own <img> + <figcaption>. So any element *inside*
            // that figure must be skipped here, or the same photo/caption becomes two blocks.
            if tag != "figure", isDescendant(of: "figure", node) { continue }
            if tag == "p", isDescendant(of: "figcaption", node) { continue }
            // Fix round 1 (Important #6): a related-card module's own `<article
            // data-post-id=...>` (Reader's own template shape) can sit nested inside the real
            // top-level `<article>` chosen as the fallback's scope root. `container.select(...)`
            // walks the whole subtree regardless of nested `<article>` boundaries, so without
            // this check the nested card's own headline/teaser paragraphs would leak into the
            // real story's body, interleaved with its genuine content. A nested `<article>` is a
            // different story -- skip anything that lives inside one.
            if isDescendant(ofNestedArticleWithin: container, node) { continue }

            switch tag {
            case "p":
                try appendParagraphOrAttachCaption(node, to: &result)
            case "h2", "h3", "h4":
                let text = try plainText(node)
                if !text.isEmpty, !isPromoJunkText(text, in: node) {
                    result.append(BodyBlock(kind: .heading, text: text, imageURLString: nil, caption: nil, credit: nil))
                }
            case "figure":
                if let block = imageBlock(fromFigure: node, baseURL: baseURL) {
                    result.append(block)
                }
            case "img":
                if let block = imageBlock(fromImg: node, baseURL: baseURL) {
                    result.append(block)
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - v1.3.1 item 3: caption leakage into body text
    //
    // Some sources place a story's photo caption as a plain <p>/<div> adjacent to the image
    // rather than inside a <figcaption> (which the figure-handling code above already handles).
    // Confirmed live 2026-07-27 against real affected articles (see the v1.3.1 report's
    // per-source table): NPR marks captions with a `.credit-caption` > `.caption-wrap` >
    // `.caption` > <p> chain (no <figure> at all), with the credit in a nested `.credit`
    // element and NPR's own "hide caption"/"toggle caption" UI toggle-button text baked into
    // the DOM as plain text alongside it; PBS's WordPress `[caption]` shortcode renders
    // `<div class="wp-caption">` wrapping the <img> and a sibling `<p class="wp-caption-text">`.
    // Per-source class hints take precedence over any heuristic here -- both real cases found
    // carry a reliable class marker, so no heuristic (photographer-name-pattern, etc.) fallback
    // was needed or implemented; see the report for why.
    private static let captionMarkerClasses: Set<String> = ["caption", "wp-caption-text", "credit-caption"]
    private static let captionCreditClass = "credit"
    private static let captionBoilerplateSelector = ".hide-caption, .toggle-caption"

    /// Whether `element` itself, or any ancestor, carries one of `captionMarkerClasses`.
    fileprivate static func isCaptionMarked(_ element: Element) -> Bool {
        var current: Element? = element
        while let node = current {
            for cls in captionMarkerClasses {
                if node.hasClass(cls) { return true }
            }
            current = node.parent()
        }
        return false
    }

    /// Extracts caption/credit text from a class-marked caption `<p>`, on a *clone* of the
    /// element so the original tree is left untouched. Pulls a nested `.credit` sub-element out
    /// as the credit (mirroring the existing figcaption `.credit` handling above) and strips
    /// known UI boilerplate (NPR's "hide caption"/"toggle caption" toggle-button text) before
    /// reading whatever plain text remains as the caption.
    fileprivate static func captionAndCredit(from element: Element) -> (caption: String?, credit: String?) {
        guard let clone = element.copy() as? Element else {
            let whole = (try? plainText(element)) ?? ""
            return (whole.isEmpty ? nil : whole, nil)
        }

        var credit: String? = nil
        if let creditMatches = try? clone.select("." + captionCreditClass), let creditElement = creditMatches.first() {
            let creditText = (try? plainText(creditElement)) ?? ""
            credit = creditText.isEmpty ? nil : creditText
            _ = try? creditElement.remove()
        }
        if let boilerplateMatches = try? clone.select(captionBoilerplateSelector) {
            _ = try? boilerplateMatches.remove()
        }

        let captionText = (try? plainText(clone)) ?? ""
        return (captionText.isEmpty ? nil : captionText, credit)
    }

    /// Shared by both `blocks(from:)` (direct-children feed-HTML) and `blocksDescendant`
    /// (page-extraction): a class-marked caption `<p>` immediately following an already-emitted
    /// `.image` block *that doesn't already have a caption* attaches to that block's
    /// caption/credit instead of becoming its own paragraph. Everything else (no class marker,
    /// no preceding image block to attach to, or a preceding image block that already has a
    /// caption -- e.g. from a real `<figure>`/`<figcaption>` -- see the review fix round's
    /// minor #4 below) falls through to ordinary paragraph handling, unless it's promo/junk
    /// (see `isPromoJunkText` below), in which case it's dropped entirely.
    ///
    /// Review fix round (minor #4): previously, when the image already had a caption, this
    /// still matched the `if` branch and silently discarded the class-marked `<p>`'s text
    /// entirely (neither attached nor kept as a paragraph) -- content loss for no reason.
    /// Gating the attach on `result[lastIndex].caption == nil` means a redundant/duplicate
    /// caption-styled paragraph now becomes an ordinary paragraph instead, so nothing vanishes.
    fileprivate static func appendParagraphOrAttachCaption(_ node: Element, to result: inout [BodyBlock]) throws {
        if isCaptionMarked(node), let lastIndex = result.indices.last, result[lastIndex].kind == .image,
           result[lastIndex].caption == nil {
            let (caption, credit) = captionAndCredit(from: node)
            result[lastIndex].caption = caption
            if result[lastIndex].credit == nil { result[lastIndex].credit = credit }
            return
        }
        let text = try plainText(node)
        guard !text.isEmpty, !isPromoJunkText(text, in: node) else { return }
        result.append(BodyBlock(kind: .paragraph, text: text, imageURLString: nil, caption: nil, credit: nil))
    }

    // MARK: - v1.3.1 item 4: "Read more" junk mid-article
    //
    // Inline promo/related paragraphs leak into bodies as ordinary <p> tags. Confirmed live
    // 2026-07-27 against real affected articles (see the v1.3.1 report's per-source table):
    // Fox ("CLICK HERE FOR MORE ... COVERAGE ON FOXNEWS.COM", entirely one <a> link; "Follow
    // Fox News Digital's <a>...</a> and subscribe to <a>...</a>.", a mix of styled text and
    // links), PBS ("READ MORE: <headline>", entirely one <a> link), BBC ("Sign up for our ...
    // newsletter <a>...</a> to keep up with ...", a link followed by trailing prose), and
    // BlockClub ("RELATED: <em><a>...</a></em>", plain <strong> lead-in text plus a linked
    // headline). None of these four real shapes are consistently "entirely a link" (Fox's and
    // BBC's aren't), so what they actually share -- and what's checked here -- is that the
    // paragraph's full text visibly OPENS with one of these known promo phrasings, not that
    // every character of it lives inside an <a>. Bounding the check to `hasPrefix` (not
    // `contains`) is what keeps this from ever touching legitimate prose that merely mentions
    // "read more"/"click here" mid-sentence (e.g. ABC7's real crisis-hotline sentences, which
    // embed a "click here" link mid-sentence, not as the paragraph's opening phrase).
    //
    // Review fix round (Important #2): "subscribe to" was removed -- it was never grounded in
    // a real confirmed match (the Fox mixed-markup case actually opens with "Follow Fox News
    // Digital's", already caught by that entry below; "subscribe to" only ever appeared
    // mid-paragraph as a second link in that same fixture, not as an opening phrase), and a
    // bare `hasPrefix` on it would delete real prose like `"Subscribe to nothing," the mayor
    // said` (see the negative test). "click here" stays, but -- unlike the other prefixes here,
    // which were only ever confirmed live alongside a real link -- it's now gated on the
    // paragraph actually containing an `<a>` (`promoPrefixesRequiringLink` below), since
    // "click here" read in isolation is plausible as genuine quoted prose with no link at all.
    //
    // v1.3.3 fix A (reader-extraction-investigation.md §6, NY Post 2/28 sampled): "Download The
    // California Post App..." renders as a plain `<h2 class="wp-block-heading">` -- WordPress's
    // generic heading-block class, shared by legitimate subheads -- so unlike the other
    // per-source junk (Reader/ABC/NBC5/NBC News/NPR/Al Jazeera, all class-/attribute-based), it
    // can only be caught by the heading's own text, not a selector. This is why
    // `isPromoJunkText` below now also runs against heading text, not just paragraphs.
    private static let promoPrefixes: [String] = [
        "read more:", "related:", "sign up for", "click here", "like what you're reading",
        "follow fox news digital", "follow live coverage", "download the"
    ]

    /// Prefixes from `promoPrefixes` above that only strip the text when its element also
    /// contains at least one `<a>` -- see the "Important #2" note above for why "click here"
    /// specifically needs this.
    ///
    /// Fix round 1 (cheap minor): "download the" was added on a single 2/28 NY Post sample and,
    /// as a bare `hasPrefix`, would strip every heading on every source that happens to open
    /// with those words -- including a legitimate one, e.g. "Download the report" as a subhead
    /// in a ProPublica investigation. Real app-download promo CTAs are always themselves a link
    /// (there's no reason to render one as plain text), so gating it the same way "click here"
    /// already is costs nothing against the one confirmed real case and protects every
    /// unconfirmed one.
    private static let promoPrefixesRequiringLink: Set<String> = ["click here", "download the"]

    /// Shared by both paragraph and heading handling (v1.3.3 fix A extended this from
    /// paragraph-only to also cover headings -- see the "download the" note above).
    private static func isPromoJunkText(_ text: String, in element: Element) -> Bool {
        let lowered = text.lowercased()
        guard let matchedPrefix = promoPrefixes.first(where: { lowered.hasPrefix($0) }) else { return false }
        guard promoPrefixesRequiringLink.contains(matchedPrefix) else { return true }
        return (try? element.select("a").first()) != nil
    }

    fileprivate static func isDescendant(of ancestorTag: String, _ element: Element) -> Bool {
        var current = element.parent()
        while let node = current {
            if node.tagName().lowercased() == ancestorTag { return true }
            current = node.parent()
        }
        return false
    }

    /// True if `element` sits inside an `<article>` that is itself a descendant of `container`
    /// (i.e. a NESTED article -- a different, unrelated story -- rather than `container` itself,
    /// which may legitimately be an `<article>`). Walks up from `element` only as far as
    /// `container`, so a `container` that IS an `<article>` never flags its own direct content.
    fileprivate static func isDescendant(ofNestedArticleWithin container: Element, _ element: Element) -> Bool {
        var current = element.parent()
        while let node = current, node !== container {
            if node.tagName().lowercased() == "article" { return true }
            current = node.parent()
        }
        return false
    }

    fileprivate static func depth(of element: Element) -> Int {
        var depth = 0
        var current = element.parent()
        while let node = current {
            depth += 1
            current = node.parent()
        }
        return depth
    }

    fileprivate static func imageBlock(fromFigure figure: Element, baseURL: URL) -> BodyBlock? {
        guard let imgMatches = try? figure.select("img"), let img = imgMatches.first() else { return nil }
        guard let url = resolveImageURL(img, baseURL: baseURL) else { return nil }

        var caption: String? = nil
        var credit: String? = nil
        if let capMatches = try? figure.select("figcaption"), let figcaption = capMatches.first() {
            if let creditMatches = try? figcaption.select(".credit"), let creditSpan = creditMatches.first() {
                credit = try? plainText(creditSpan)
                _ = try? creditSpan.remove()
            }
            let captionText = (try? plainText(figcaption)) ?? ""
            caption = captionText.isEmpty ? nil : captionText
        }
        return BodyBlock(kind: .image, text: nil, imageURLString: url.absoluteString, caption: caption, credit: credit)
    }

    fileprivate static func imageBlock(fromImg img: Element, baseURL: URL) -> BodyBlock? {
        guard let url = resolveImageURL(img, baseURL: baseURL) else { return nil }
        return BodyBlock(kind: .image, text: nil, imageURLString: url.absoluteString, caption: nil, credit: nil)
    }

    // MARK: - Lazyload resolution: data-srcset (widest) > data-src > src

    fileprivate static func resolveImageURL(_ img: Element, baseURL: URL) -> URL? {
        let srcset = (try? img.attr("data-srcset")) ?? ""
        if !srcset.isEmpty {
            let candidates: [(String, Int)] = srcset.split(separator: ",").compactMap { chunk in
                let entry = String(chunk).trimmingCharacters(in: .whitespaces)
                let parts = entry.split(separator: " ")
                guard let urlPart = parts.first else { return nil }
                var width = 0
                if parts.count > 1 {
                    let descriptor = parts[1]
                    if descriptor.hasSuffix("w"), let w = Int(descriptor.dropLast()) {
                        width = w
                    }
                }
                return (String(urlPart), width)
            }
            if let widest = candidates.max(by: { $0.1 < $1.1 }) {
                return absolutize(widest.0, baseURL: baseURL)
            }
        }

        let dataSrc = (try? img.attr("data-src")) ?? ""
        if !dataSrc.isEmpty {
            return absolutize(dataSrc, baseURL: baseURL)
        }

        let src = (try? img.attr("src")) ?? ""
        return absolutize(src, baseURL: baseURL)
    }

    fileprivate static func absolutize(_ raw: String, baseURL: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    fileprivate static func plainText(_ element: Element) throws -> String {
        let raw = try element.text()
        let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - v1.3.3 fix C: trim a trailing chrome-only run
    //
    // reader-extraction-investigation.md §3/§6(b): a "More in X" / "Reader Recommends: Y"
    // related-posts heading stack (and similar recirculation widgets on other sources) can
    // survive selector-stripping and land at the very end of the block list. After the last
    // real paragraph, drop a trailing run of blocks that carries no paragraph text -- but never
    // touch a captioned image (a real closing photo counts as content, not furniture) and never
    // trim a run shorter than 2 blocks (a single trailing image -- an uncaptioned closer photo
    // -- is common and legitimate on its own). Scanning backward from the true end and stopping
    // at the first non-trimmable block also guarantees this never touches a heading that's
    // actually followed by real prose: if it were, the scan would have already stopped there.
    fileprivate static func trimTrailingChromeRun(_ blocks: [BodyBlock]) -> [BodyBlock] {
        var cutIndex = blocks.count
        var index = blocks.count - 1
        while index >= 0 {
            let block = blocks[index]
            let isTrimmable: Bool
            switch block.kind {
            case .paragraph:
                isTrimmable = false
            case .heading:
                isTrimmable = true
            case .image:
                isTrimmable = !(block.caption?.isEmpty == false)
            }
            guard isTrimmable else { break }
            cutIndex = index
            index -= 1
        }
        guard blocks.count - cutIndex >= 2 else { return blocks }
        return Array(blocks[0..<cutIndex])
    }

    // MARK: - Assembly: hero + deduped allImageURLs

    fileprivate static func buildArticle(title: String, blocks rawBlocks: [BodyBlock], ogImageURL: URL?,
                                          author: String? = nil, authorInstitution: String? = nil,
                                          url: URL? = nil, publishedAt: Date? = nil) -> ExtractedArticle {
        // Cheap minor (fix round 1): trimTrailingChromeRun runs BEFORE hero/allImageURLs are
        // computed below, and both are derived from `blocks` (the trimmed list), not
        // `rawBlocks` -- so an uncaptioned image that fix C trims off the tail is already gone
        // by the time image assembly runs. It correctly never lingers in allImageURLs (and can
        // never become the hero either, since `firstImageURL` below also reads `blocks`).
        let blocks = trimTrailingChromeRun(rawBlocks)
        let firstImageURL = blocks.first(where: { $0.kind == .image })
            .flatMap { $0.imageURLString }
            .flatMap { URL(string: $0) }
        let heroImageURL = ogImageURL ?? firstImageURL

        var allImageURLs: [URL] = []
        var seen = Set<String>()
        if let hero = heroImageURL, seen.insert(hero.absoluteString).inserted {
            allImageURLs.append(hero)
        }
        for block in blocks where block.kind == .image {
            if let s = block.imageURLString, let url = URL(string: s), seen.insert(url.absoluteString).inserted {
                allImageURLs.append(url)
            }
        }

        return ExtractedArticle(title: title, byline: nil, bodyBlocks: blocks, heroImageURL: heroImageURL,
                                 allImageURLs: allImageURLs, author: author, authorInstitution: authorInstitution,
                                 url: url, publishedAt: publishedAt)
    }

    func extract(fromPageHTML html: String, articleURL: URL, item: FeedItem, config: SourceConfig) throws -> ExtractedArticle {
        let doc = try SwiftSoup.parse(html)

        // v1.8 (spec item 1): read the page's own byline BEFORE `stripJunk` runs, not after.
        // Live-verified 2026-07-29: The Conversation's author block sits inside a bare
        // `<aside class="content-sidebar">` -- exactly what `stripJunk`'s generic "script, style,
        // nav, aside, .related" set removes unconditionally below. Reading it first means this
        // never depends on the author markup surviving junk-stripping, which it structurally
        // cannot on this source.
        let pageByline = Self.pageAuthorAndInstitution(in: doc)
        // Read for the same reason as the byline: `stripJunk` removes every <script>, which is where
        // JSON-LD `datePublished` lives.
        let pagePublished = Self.pagePublishedAt(in: doc)

        Self.stripJunk(doc, additionalSelectors: config.junkSelectors)

        var container: Element? = nil
        if let selector = config.bodySelector, let matches = try? doc.select(selector) {
            container = matches.first()
        }

        var blocks: [BodyBlock] = []
        if let content = container {
            blocks = try Self.blocksDescendant(from: content, baseURL: articleURL)
        }

        // A selector hit that's too thin (nested markup yielding under 3 real paragraphs) is
        // just as broken as a selector miss for our purposes -- fall through to the generic
        // cluster finder in both cases.
        let paragraphCount = blocks.filter { $0.kind == .paragraph }.count
        if container == nil || paragraphCount < 3 {
            if let fallbackContainer = Self.largestParagraphCluster(in: doc) {
                blocks = try Self.blocksDescendant(from: fallbackContainer, baseURL: articleURL)
            }
        }

        var ogImageURL = Self.ogImageURL(in: doc, baseURL: articleURL)

        // A social image with a logo/text stamp burned in by the publisher's image service is a
        // share card, not the article's photograph -- prefer the page's own lead photo, else its
        // first body photo (which then leaves the body so it is not shown twice). See
        // "Stamped social images" below.
        if let og = ogImageURL, Self.isStampedSocialImage(og),
           let replacement = Self.unstampedHero(in: doc, blocks: blocks, baseURL: articleURL) {
            ogImageURL = replacement.url
            blocks = replacement.blocks
        }

        // v1.8 (spec item 1): the page's own byline wins outright when present; the feed's
        // combined byline (Atom <author><name> / RSS <dc:creator>, see FeedItem.author) is only
        // ever consulted as a fallback when the page yielded NOTHING -- if the page supplied an
        // author but no institution, that's the honest final answer, not a cue to go fill the
        // institution in from a different, feed-sourced byline (which could describe a
        // different affiliation entirely on a co-authored piece).
        let author: String?
        let authorInstitution: String?
        if let pageAuthorName = pageByline.author {
            author = pageAuthorName
            authorInstitution = pageByline.institution
        } else if let feedAuthorRaw = item.author {
            let split = Self.splitFeedByline(feedAuthorRaw)
            author = split.author
            authorInstitution = split.institution
        } else {
            author = nil
            authorInstitution = nil
        }

        return Self.buildArticle(title: item.title, blocks: blocks, ogImageURL: ogImageURL,
                                  author: author, authorInstitution: authorInstitution, url: articleURL,
                                  publishedAt: pagePublished)
    }

    // MARK: - Page publish time
    //
    // Some feeds carry no date the parser can read (NBC 5's was zone-less, Sun-Times' had fractional
    // seconds; both fixed in FeedParser) and a page-extract source's PAGE always states one. Order of
    // preference: the ORIGINAL publish time only -- `article:published_time` and the like, then JSON-LD
    // `datePublished`, then a `<time itemprop=datePublished>` -- never `dateModified`/`updated`. A stamp
    // without an explicit zone (or a bare date) is NOT used: `FeedDates.parse` reads it as nil.

    /// The page's original publish time, or nil when it states none with a zone.
    static func pagePublishedAt(inPageHTML html: String) -> Date? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        return pagePublishedAt(in: doc)
    }

    fileprivate static func pagePublishedAt(in doc: Document) -> Date? {
        let metaSelectors = [
            "meta[property=article:published_time]", "meta[property=og:article:published_time]",
            "meta[name=article:published_time]", "meta[itemprop=datePublished]", "meta[name=pubdate]",
            "meta[name=publish-date]", "meta[name=parsely-pub-date]", "meta[name=DC.date.issued]"
        ]
        for selector in metaSelectors {
            guard let metas = try? doc.select(selector) else { continue }
            for meta in metas.array() {
                if let date = FeedDates.parse(try? meta.attr("content")) { return date }
            }
        }
        if let scripts = try? doc.select("script[type=application/ld+json]") {
            func walk(_ node: Any) -> Date? {
                if let array = node as? [Any] {
                    for element in array { if let date = walk(element) { return date } }
                    return nil
                }
                guard let dict = node as? [String: Any] else { return nil }
                if let stated = dict["datePublished"] as? String, let date = FeedDates.parse(stated) { return date }
                for key in dict.keys.sorted() { if let value = dict[key], let date = walk(value) { return date } }
                return nil
            }
            for script in scripts.array() {
                guard let text = try? script.data(), let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data), let date = walk(json) else { continue }
                return date
            }
        }
        for selector in ["time[itemprop=datePublished]", "time.published", "time.entry-date.published", "time[pubdate]"] {
            guard let times = try? doc.select(selector) else { continue }
            for time in times.array() {
                if let date = FeedDates.parse(try? time.attr("datetime")) { return date }
            }
        }
        return nil
    }

    // MARK: - v1.8: author / institution extraction (spec item 1)
    //
    // Generic across every source (not gated to any one sourceID -- see this file's other
    // per-source special-casing, e.g. `nypost`'s SourceConfig.id checks, for contrast): schema.org
    // Person byline markup (`[itemprop=author]`) is a common convention across many news CMSes,
    // not something specific to The Conversation. `[itemprop=name]` alone would be too broad (an
    // article's own headline or an organization block can carry the same schema.org property), so
    // the selector below requires it to be a DESCENDANT of `[itemprop=author]` specifically.

    /// Live-verified 2026-07-29 against theconversation.com: the author name lives at
    /// `[itemprop=author] [itemprop=name]`, with an optional sibling `<p class="role">` (inside
    /// the same `[itemprop=author]` container) carrying "Job Title, Institution" -- the
    /// institution is derived by anchoring on institution keywords, not comma position (see
    /// `institutionFromRoleText`'s doc comment; v1.8.2 replaced v1.8-fixes' first-comma-segment
    /// approach, which -- like the original last-comma approach it replaced -- truncated a
    /// different real 6/50 of live role texts).
    /// Falls back to a generic `<meta name="author">` tag (common across many CMSes; no reliable
    /// institution shape, so that path never returns one) when no schema.org markup is found.
    fileprivate static func pageAuthorAndInstitution(in doc: Document) -> (author: String?, institution: String?) {
        if let nameMatches = try? doc.select("[itemprop=author] [itemprop=name]"), let nameElement = nameMatches.first() {
            let name = (try? plainText(nameElement)) ?? ""
            guard !name.isEmpty else { return (nil, nil) }
            var institution: String? = nil
            if let authorMatches = try? doc.select("[itemprop=author]"), let authorContainer = authorMatches.first(),
               let roleMatches = try? authorContainer.select(".role"), let roleElement = roleMatches.first() {
                institution = institutionFromRoleText((try? plainText(roleElement)) ?? "")
            }
            return (name, institution)
        }
        if let metaMatches = try? doc.select("meta[name=author]"), let meta = metaMatches.first(),
           let content = try? meta.attr("content") {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (nil, nil) }
            return (trimmed, nil)
        }
        return (nil, nil)
    }

    /// Institution-indicating keywords used to anchor the institution segment within a "TITLE,
    /// INSTITUTION" role/byline string (see `institutionFromRoleText` below) rather than relying
    /// on comma POSITION. Matched case-insensitively on WHOLE-WORD boundaries only, never a bare
    /// substring -- this file has a documented history of substring-collision bugs elsewhere (see
    /// `promoPrefixes`/`captionMarkerClasses` above for the same discipline), and an unbounded
    /// `.contains` here would, for example, match "Trust" inside "Trustee".
    ///
    /// Verified and extended 2026-07-29 against a live re-fetch of all 50 real
    /// theconversation.com/us/articles.atom entries (see `.superpowers/sdd/v1.8.2-report.md` for
    /// the full 50-row measurement). "UMass" was added specifically because it's a real, recurring
    /// institution short-name in that live sample (Christopher Davis's role text names "UMass
    /// Amherst" with no other keyword-bearing word at all) -- "Penn State" is the other
    /// keyword-less short name observed live (Medha D. Makhlouf, William Burgos) but was NOT
    /// added, because both of its live occurrences already resolve correctly through the
    /// no-keyword fallback below (their full role text has only one comma) -- adding a keyword
    /// for a case the fallback already gets right would be speculative, not evidence-based.
    /// University/College/Institute/School/Center all fired on real rows in the same sample;
    /// Academy, Polytechnic, Hospital, Museum, Laboratory, Centre, Foundation, Trust, Observatory,
    /// and the non-English university words were not observed in this 50-row sample but are kept
    /// as plausible, low-risk future matches -- a Conversation contributor affiliated with a
    /// museum or a non-US university is a certainty over time on this source, not a hypothetical.
    private static let institutionKeywords: [String] = [
        "University", "Universities", "College", "Institute", "Institution", "School", "Academy",
        "Polytechnic", "Hospital", "Museum", "Laboratory", "Center", "Centre", "Foundation", "Trust",
        "Observatory", "Universidad", "Université", "Universität", "UMass"
    ]

    private static func containsInstitutionKeyword(_ segment: String) -> Bool {
        for keyword in institutionKeywords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
            if segment.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// Splits a "TITLE, INSTITUTION" role/byline string into its institution, anchoring on
    /// institution KEYWORDS (see `institutionKeywords` above) instead of comma POSITION.
    ///
    /// HISTORY: v1.8 shipped `lastCommaSegment` (take the LAST comma-separated segment), which
    /// truncated any institution name that itself contains a comma ("University of California,
    /// San Francisco" -> "San Francisco"). v1.8-fixes replaced it with `institutionAfterFirstComma`
    /// (take everything after the FIRST comma), which fixed that but broke a DIFFERENT, real 6/50
    /// (12%) of a live sample: role texts where the JOB TITLE itself contains a comma (an
    /// endowed-chair name like "William R. Kenan, Jr. Professor...", an Oxford-comma department
    /// list, a dual title/institution joined by "; "). Both are pure comma-position heuristics;
    /// neither can work in general, because a real institution name can also contain a comma. See
    /// `institutionAfterFirstComma`'s own doc comment below for the full before/after history.
    ///
    /// ALGORITHM (validated against a live 2026-07-29 re-fetch of all 50 real Conversation
    /// entries -- see `.superpowers/sdd/v1.8.2-report.md` for the row-by-row measurement: 49/50
    /// correct, versus 44/50 for either comma-position approach):
    ///   1. Split on commas into trimmed segments.
    ///   2. Find the LAST segment that contains an institution keyword -- this anchors the
    ///      institution's end. Not the FIRST: "Lecturer in Museum Studies, University of Leeds"
    ///      has a keyword ("Museum") in segment 0 too, and taking the first match would wrongly
    ///      include the whole job title (see `..._keywordAppearsInRoleNotInstitution_...` test).
    ///   3. Walk backward from just before that anchor, absorbing each additional segment that
    ///      ALSO contains a keyword -- this is what keeps compound institution names intact
    ///      ("Institute for Health & Aging, University of California, San Francisco",
    ///      "Binghamton University, State University of New York") -- but NEVER absorb segment 0.
    ///      Segment 0 is, by this source's own "TITLE, ..., INSTITUTION" convention, always the
    ///      start of the job title; when a keyword-bearing phrase (a center, school, or college
    ///      name) is grammatically PART of that title via a preposition ("Executive Director OF
    ///      THE Center for...", "Professor IN THE College of..."), it is fused into segment 0 with
    ///      no comma of its own, so this boundary is exactly what excludes it -- live-verified via
    ///      Solomon Greene's real role text (see `..._keywordFusedIntoTitleViaPreposition_...`
    ///      test) alongside Karen Barrett's, where the equivalent phrase legitimately IS its own
    ///      appositive segment (not fused into segment 0) and correctly survives.
    ///   4. Institution = every segment from the final absorbed index through the end, joined by
    ///      ", ".
    ///   5. If NO segment contains a keyword at all, fall back to `institutionAfterFirstComma` and
    ///      log it via `DiagnosticsLog` as unresolved, so it can be counted rather than silently
    ///      trusted -- e.g. bare short names like "Penn State" (2/50 in the live sample) fall
    ///      through here. Both happened to still land on the right answer, because their full
    ///      role text has only one comma -- but this path is not guaranteed correct in general.
    ///
    /// KNOWN REMAINING FAILURE (1/50 in the live sample, disclosed rather than hidden -- see
    /// `..._knownLimitation_...` test): Jodyn Platt's real role text includes "Medical School
    /// Associate" as a job-title clause -- not segment 0, and not fused into it -- that happens to
    /// contain the keyword "School" immediately before the real institution chain "School of
    /// Public Health, University of Michigan", so backward absorption over-includes it. Resolving
    /// this would need a semantic role-word signal ("Professor"/"Associate"/etc.) on top of the
    /// institution-keyword list -- deliberately not added here, since one case in a 50-row live
    /// sample is not enough evidence to justify a second ad hoc vocabulary.
    private static func institutionFromRoleText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let segments = trimmed.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }
        guard segments.count > 1 else { return segments[0] }

        guard let lastKeywordIndex = segments.lastIndex(where: containsInstitutionKeyword) else {
            DiagnosticsLog.shared.log(.warn, source: nil,
                                       "institution parse: no keyword matched in role text \"\(trimmed)\" -- falling back to first-comma split")
            return institutionAfterFirstComma(trimmed)
        }

        var startIndex = lastKeywordIndex
        var walkIndex = lastKeywordIndex - 1
        while walkIndex >= 1 {
            guard containsInstitutionKeyword(segments[walkIndex]) else { break }
            startIndex = walkIndex
            walkIndex -= 1
        }

        let institution = segments[startIndex...].joined(separator: ", ")
        return institution.isEmpty ? nil : institution
    }

    /// The institution in a "TITLE, INSTITUTION" role/byline string: everything AFTER the FIRST
    /// comma, trimmed, kept intact even when it contains further commas.
    ///
    /// v1.8.2: this is no longer the primary institution parser (see `institutionFromRoleText`
    /// above) -- it survives ONLY as the fallback for the rare role text that contains a comma but
    /// no recognized institution keyword at all (e.g. a bare, keyword-less short name). Kept
    /// because it's still a reasonable guess in that situation (right whenever the role text has
    /// exactly one comma, which is the common case for a keyword-less short name), and it's better
    /// than emitting nothing.
    ///
    /// Returns the WHOLE trimmed text when there's no comma at all (a bare institution with no
    /// separate job title, e.g. `.role` = "Quinnipiac University") -- nil only for an empty/
    /// all-whitespace input or a comma with nothing after it.
    private static func institutionAfterFirstComma(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let commaIndex = trimmed.firstIndex(of: ",") else { return trimmed }
        let after = trimmed[trimmed.index(after: commaIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? nil : after
    }

    /// Splits a combined "Name, Title, Institution" feed byline (the shape The Conversation's
    /// Atom `<author><name>` uses -- see `FeedItem.author`'s doc comment) into (author,
    /// institution). ONLY ever invoked as a feed-content fallback when the article page itself
    /// yielded no author at all -- see both call sites above. The name is the segment before the
    /// first comma; the institution is then `institutionFromRoleText` applied to whatever follows
    /// (see that function's doc comment for the keyword-anchored algorithm).
    fileprivate static func splitFeedByline(_ raw: String) -> (author: String, institution: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCommaIndex = trimmed.firstIndex(of: ",") else { return (trimmed, nil) }
        let author = trimmed[trimmed.startIndex..<firstCommaIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimmed[trimmed.index(after: firstCommaIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { return (trimmed, nil) }
        return (author, institutionFromRoleText(remainder))
    }

    // MARK: - Junk removal

    /// `additionalSelectors` is `SourceConfig.junkSelectors` -- per-source whole-subtree strips
    /// (v1.3.1 item 4) layered on top of the fixed generic set, e.g. NY Post's
    /// `.single__inline-module` newsletter-signup widgets.
    private static func stripJunk(_ doc: Document, additionalSelectors: [String] = []) {
        for selector in ["script", "style", "nav", "aside", ".related"] + additionalSelectors {
            if let matches = try? doc.select(selector) {
                try? matches.remove()
            }
        }
    }

    // MARK: - v1.3.3 fix B: bound the fallback to a semantic content root
    //
    // reader-extraction-investigation.md §2b/§6(a): the fallback below excludes only <body>
    // from candidacy, so on any page where the true outermost wrapper div contains both site
    // chrome (masthead tagline, footer widgets) *and* the article, that wrapper always
    // out-scores the real, thinner article container -- Chicago Reader's `<div id="page">` won
    // purely because it also contained two masthead `<p>` tags. Before falling through to a
    // whole-document search, try scoping candidacy to a single `<main>`/`[role=main]` landmark,
    // else the *best-scoring* top-level `<article>` (not nested inside another
    // `<article>`/`<main>` -- a related-posts module's own `<article data-post-id=...>` cards
    // must never be mistaken for the real story container). Only when neither exists does
    // candidacy span the whole document, unchanged from pre-v1.3.3 behavior.
    //
    // Fix round 1 (Important #4):
    //   (a) "a single `<main>`/`[role=main]` landmark" now means exactly that -- if the
    //       document has more than one match, that's not a usable landmark (which one is the
    //       real content region?), so this falls through to the article branch instead of
    //       blindly taking the first match.
    //   (b) the article branch now scores every top-level `<article>` and returns the
    //       BEST-scoring one, not the first one encountered in document order -- a teaser or
    //       trending-story `<article>` card rendered before the real story (a common landing/
    //       hub-page pattern) would otherwise become the root instead of the actual article.
    private static func fallbackScopeRoot(in doc: Document) -> Element? {
        if let mainMatches = try? doc.select("main, [role=main]"), mainMatches.array().count == 1,
           let main = mainMatches.first() {
            return singleNestedArticle(within: main) ?? main
        }
        if let articleMatches = try? doc.select("article") {
            let topLevelArticles = articleMatches.array().filter {
                !isDescendant(of: "article", $0) && !isDescendant(of: "main", $0)
            }
            return bestScoringCandidate(among: topLevelArticles)
        }
        return nil
    }

    // Fix round 1 (Minor, post-round #2): the most common CMS layout is a `<main>` that WRAPS
    // the real `<article>`, rather than being the article itself. Without this, every
    // article-internal container is excluded from `largestParagraphCluster`'s scoped candidacy by
    // the nested-article rule (tag filter + `isDescendant(ofNestedArticleWithin:)`), leaving
    // `<main>` itself as the only candidate -- scored only on paragraphs OUTSIDE the article. A
    // stray real `<p>` in `<main>` (a dek, byline blurb, "listen to this article" line) then wins
    // candidacy on its own and becomes the entire body; with no such paragraph, `<main>` always
    // scores 0 and falls through to the unbounded whole-document search, making this release's
    // bounding protection inert on the most common page shape. When `<main>` contains exactly one
    // non-nested `<article>`, descend and use that `<article>` as the scope root directly, so
    // candidacy is bounded to the real story container. Zero or multiple non-nested articles is
    // ambiguous (which one is the real story?) -- keep returning `<main>` unchanged in that case.
    private static func singleNestedArticle(within main: Element) -> Element? {
        guard let articleMatches = try? main.select("article") else { return nil }
        let nonNestedArticles = articleMatches.array().filter { !isDescendant(of: "article", $0) }
        guard nonNestedArticles.count == 1 else { return nil }
        return nonNestedArticles.first
    }

    // MARK: - Generic fallback: the div/section/article with the highest count of descendant
    // <p> elements at any depth (not just direct children -- handles nested wrapper markup),
    // preferring the deepest candidate on ties, with total text length as a last tiebreak.
    // <body> itself is deliberately excluded from candidacy: it's an ancestor of every
    // paragraph on the page, so on a page with real distractor content elsewhere (nav,
    // sidebar, footer) its raw descendant count would always beat the actual article
    // container and we'd extract the whole page instead of just the story.
    //
    // v1.3.3 fix B: when `fallbackScopeRoot` finds a semantic content root, candidacy is bound
    // to that root (plus its own div/section/article descendants) instead of the whole
    // document -- a site-wide wrapper must never win when a real content boundary exists. The
    // scope root itself is always included as a candidate (unlike <body> above, it's already a
    // bounded scope, so it's fair game to win outright).
    //
    // Fix round 1 (Important #4c): if the chosen scope root's own subtree has no scoring
    // candidate at all (e.g. a `<main>` landmark that happens to contain zero real paragraphs
    // itself -- `fallbackScopeRoot` takes a `<main>` unconditionally, with no score check, so
    // this is a real reachable case, unlike the article branch above which already requires a
    // positive score to be chosen at all), this used to return nil and silently drop the
    // article. Falling through to the unbounded whole-document search below instead means a
    // real article body sitting entirely outside an empty/decorative `<main>` still gets found,
    // rather than discarded.
    private static func largestParagraphCluster(in doc: Document) -> Element? {
        if let scopeRoot = fallbackScopeRoot(in: doc) {
            var candidates: [Element] = [scopeRoot]
            if let matches = try? scopeRoot.select("div, section, article") {
                // Fix round 2 (companion to the descendantParagraphCount fix above): now that
                // scoring correctly excludes a nested <article>'s own paragraphs from its
                // ANCESTOR's count, a nested <article> scored against ITSELF (as its own
                // container) keeps its full own count -- which can let a thin-but-clean related
                // card outscore, and win outright over, the real scopeRoot it's nested inside.
                // `scopeRoot.select(...)` never returns scopeRoot itself, so any "article" match
                // here is by definition a nested boundary; exclude it and anything living inside
                // it from candidacy, same as `fallbackScopeRoot`'s own top-level article filter
                // and `blocksDescendant`'s emission-time skip already do.
                candidates.append(contentsOf: matches.array().filter {
                    $0.tagName().lowercased() != "article" && !isDescendant(ofNestedArticleWithin: scopeRoot, $0)
                })
            }
            if let best = bestScoringCandidate(among: candidates) {
                return best
            }
            // Fall through to the unbounded search below rather than returning nil here.
        }

        guard let candidates = try? doc.select("div, section, article") else { return nil }
        if let best = bestScoringCandidate(among: candidates.array()) {
            return best
        }
        // Last resort: paragraphs sitting directly under <body> with no wrapping div at all.
        if let body = doc.body(), descendantParagraphCount(body) > 0 {
            return body
        }
        return nil
    }

    private static func bestScoringCandidate(among candidates: [Element]) -> Element? {
        var best: Element? = nil
        var bestScore = 0
        var bestDepth = -1
        var bestTextLength = 0
        for candidate in candidates {
            let score = descendantParagraphCount(candidate)
            guard score > 0 else { continue }
            let candidateDepth = depth(of: candidate)
            let textLength = (try? candidate.text().count) ?? 0
            let isBetter = best == nil
                || score > bestScore
                || (score == bestScore && candidateDepth > bestDepth)
                || (score == bestScore && candidateDepth == bestDepth && textLength > bestTextLength)
            if isBetter {
                best = candidate
                bestScore = score
                bestDepth = candidateDepth
                bestTextLength = textLength
            }
        }
        return best
    }

    // Fix round 2 (Minor, in the hardened path): this must skip the exact same nested-article
    // descendants that `blocksDescendant` skips at emission time (via
    // `isDescendant(ofNestedArticleWithin:)`), or scoring and emission disagree about what
    // counts as content. Without this, a scope-root candidate can WIN scoring on paragraphs
    // that live inside a nested `<article>` (e.g. a related-card module's own teaser
    // paragraphs) -- paragraphs it will never actually emit -- yielding a near-empty body even
    // though the score itself was positive, which also means the no-candidate fallback below
    // never fires to rescue it.
    private static func descendantParagraphCount(_ element: Element) -> Int {
        guard let matches = try? element.select("p") else { return 0 }
        var count = 0
        for p in matches.array() {
            if isDescendant(of: "figure", p) || isDescendant(of: "figcaption", p) { continue }
            if isDescendant(ofNestedArticleWithin: element, p) { continue }
            let text = (try? plainText(p)) ?? ""
            if !text.isEmpty { count += 1 }
        }
        return count
    }

    // MARK: - Stamped social images (hero selection)
    //
    // A page's og:image is a SHARE CARD, not necessarily the article's photograph, and some
    // publishers' image services stamp their logo (or text) onto it. Confirmed live 2026-10-11 on
    // theguardian.com, where EVERY article's og:image is a signed URL of the form
    //   i.guim.co.uk/img/media/<asset>/<crop>/master/<n>.jpg?width=1200&height=630&quality=85
    //   &auto=format&fit=crop&precrop=40:21,...&overlay-align=bottom%2Cleft&overlay-width=100p
    //   &overlay-base64=<base64 of "/img/static/overlays/tg-default.png">&enable=upscale&s=<sig>
    // i.e. a 1200x630 landscape CROP of the photo with "The Guardian" burned into the corner. The
    // URL is signed (`s=`), so the overlay parameters cannot simply be removed. The same page
    // offers the real photograph: its lead figure's <picture> lists signed renditions up to 1400 px
    // wide (`width=700&dpr=2&s=none&crop=none`).
    //
    // The rule, applied only when the og:image URL carries a stamp parameter (so every other
    // source -- sampled 2026-10-11, 13 of 14 clean -- behaves exactly as before):
    //   1. the page's lead figure: the first <figure> with a usable image that comes before the
    //      first real body paragraph, taking its widest page-offered JPEG/PNG rendition;
    //   2. else the first image block of the extracted body;
    //   3. else keep the og:image (a branded photo beats no photo).
    // Whichever photo is promoted to hero is removed from the body's first image block when it is
    // the same photo, so the reader never shows it twice. Trade-off, stated plainly: a caption or
    // credit that lived only on that removed block goes with it (the reader's hero has no caption
    // slot of its own). For Guardian the lead sits outside the body, so nothing is removed and
    // nothing is lost.

    /// Query-parameter NAMES that ask an image service to burn something onto the picture:
    /// `overlay*` (Guardian/Fastly `overlay-base64`, `overlay-align`, ...), `watermark*`, and the
    /// imgix text/mark/blend families (`txt`, `txt64`, `txt-size`, `mark`, `mark64`, `blend`, ...).
    /// Matched against whole parameter names, never substrings, so `markdown` or a path word
    /// cannot trip it.
    private static let stampParameterPattern = "^(overlay.*|watermark.*|(txt|mark|blend)(64|-[a-z0-9]+)?)$"

    /// True when `url` carries a logo/text-stamping query parameter (see above).
    static func isStampedSocialImage(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains {
            $0.name.range(of: stampParameterPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A lead photo narrower than this (in pixels, when the page says) is a thumbnail, not a hero.
    private static let minimumHeroWidth = 600
    /// The "lead region" of a page ends at the first body paragraph this long (characters).
    private static let leadRegionEndsAtParagraphLength = 60

    private struct Rendition {
        let url: URL
        /// Effective pixel width the page advertises for this URL; 0 when it says nothing.
        let width: Int
    }

    /// The replacement hero and the (possibly shortened) body blocks, or nil when the page offers
    /// no unstamped alternative.
    private static func unstampedHero(in doc: Document, blocks: [BodyBlock],
                                      baseURL: URL) -> (url: URL, blocks: [BodyBlock])? {
        if let lead = leadFigure(in: doc, baseURL: baseURL) {
            var remaining = blocks
            // The lead figure may ALSO be the body's first image block (it is, wherever the body
            // selector encloses the lead -- e.g. BBC's `article`). Remove that block: exact match
            // on the URL this very figure produces as a block, else the same photo under another
            // rendition (shared asset id) as the body's FIRST image block only.
            let ownBlockURL = (try? lead.figure.select("img").first())
                .flatMap { resolveImageURL($0, baseURL: baseURL)?.absoluteString }
            if let ownBlockURL,
               let index = remaining.firstIndex(where: { $0.kind == .image && $0.imageURLString == ownBlockURL }) {
                remaining.remove(at: index)
            } else if let index = remaining.firstIndex(where: { $0.kind == .image }),
                      let firstURL = remaining[index].imageURLString.flatMap({ URL(string: $0) }),
                      samePhoto(firstURL, lead.rendition.url) {
                remaining.remove(at: index)
            }
            return (lead.rendition.url, remaining)
        }
        if let index = blocks.firstIndex(where: {
            guard $0.kind == .image, let s = $0.imageURLString, let u = URL(string: s) else { return false }
            return !isStampedSocialImage(u)
        }), let url = blocks[index].imageURLString.flatMap({ URL(string: $0) }) {
            var remaining = blocks
            remaining.remove(at: index)
            return (url, remaining)
        }
        return nil
    }

    /// The page's lead figure and its best rendition. Scans the story's `<figure>`s in document
    /// order, but only until the first real body paragraph -- a mid-article photo or a related-
    /// stories thumbnail is never "the lead".
    private static func leadFigure(in doc: Document, baseURL: URL) -> (figure: Element, rendition: Rendition)? {
        let scope: Element = fallbackScopeRoot(in: doc) ?? doc.body() ?? doc
        guard let nodes = try? scope.select("figure, p") else { return nil }
        for node in nodes.array() {
            if isDescendant(ofNestedArticleWithin: scope, node) { continue }
            if node.tagName().lowercased() == "p" {
                if isDescendant(of: "figure", node) || isDescendant(of: "figcaption", node) { continue }
                if ((try? plainText(node)) ?? "").count >= leadRegionEndsAtParagraphLength { return nil }
                continue
            }
            if isDescendant(of: "figure", node) { continue }
            guard let rendition = bestRendition(inFigure: node, baseURL: baseURL) else { continue }
            if rendition.width > 0, rendition.width < minimumHeroWidth { continue }
            if isStampedSocialImage(rendition.url) { continue }
            return (node, rendition)
        }
        return nil
    }

    /// The best JPEG/PNG rendition a figure's image offers (see `renditionCandidates` and `pickRendition`).
    private static func bestRendition(inFigure figure: Element, baseURL: URL) -> Rendition? {
        guard let img = (try? figure.select("img"))?.first() else { return nil }
        let found = renditionCandidates(forImage: img, baseURL: baseURL)
        return pickRendition(from: found.all, imgSrc: found.imgSrc)
    }

    /// The pipeline keeps a photo at 1400 px (the aggregator's cap; the phone's is 1600), so more than
    /// that is wasted bytes. Of the candidates whose width the page states: the SMALLEST that reaches
    /// `heroTargetWidth`, else the widest there is. When the page states no width for any, the `<img>`
    /// the browser would show.
    private static let heroTargetWidth = 1400
    /// A candidate wider than this is a camera original (Block Club's srcset ends in a 4928 px file):
    /// megabytes to fetch for a photo that is stored at 1400, so it is only used when it is all there is.
    private static let heroOriginalWidth = 3200

    private static func pickRendition(from candidates: [Rendition], imgSrc: Rendition?) -> Rendition? {
        guard let first = candidates.first else { return nil }
        let known = candidates.filter { $0.width > 0 }
        guard !known.isEmpty else { return imgSrc ?? first }
        let sensible = known.filter { $0.width <= heroOriginalWidth }
        let pool = sensible.isEmpty ? known : sensible
        if let smallestEnough = pool.filter({ $0.width >= heroTargetWidth }).min(by: { $0.width < $1.width }) {
            return smallestEnough
        }
        return pool.max(by: { $0.width < $1.width })
    }

    /// Every JPEG/PNG rendition one image offers: all `srcset`/`data-srcset` candidates of its
    /// `<picture>` sources and `<img>` (WebP/AVIF skipped -- the phone and the aggregator both want a
    /// plain JPEG/PNG), plus `src`/`data-src` (`data:` lazy-load placeholders skipped). Width comes from
    /// a `w` descriptor, else `x` x the declared width, else the URL's own `width`/`w` x `dpr`
    /// (Guardian encodes size in the query), else the `width` attribute; 0 = the page doesn't say.
    private static func renditionCandidates(forImage img: Element,
                                            baseURL: URL) -> (all: [Rendition], imgSrc: Rendition?) {
        var carriers: [Element] = [img]
        if let picture = img.parent(), picture.tagName().lowercased() == "picture",
           let all = try? picture.select("source, img") {
            carriers = all.array()
        }

        var candidates: [Rendition] = []
        var imgSrc: Rendition?
        for carrier in carriers {
            let isSource = carrier.tagName().lowercased() == "source"
            let type = ((try? carrier.attr("type")) ?? "").lowercased()
            if isSource, type.contains("webp") || type.contains("avif") { continue }
            let declaredWidth = Int(((try? carrier.attr("width")) ?? "").trimmingCharacters(in: .whitespaces)) ?? 0

            for attribute in ["srcset", "data-srcset"] {
                for (raw, descriptor) in srcsetCandidates((try? carrier.attr(attribute)) ?? "") {
                    guard let url = absolutize(raw, baseURL: baseURL), isPlainRaster(url) else { continue }
                    candidates.append(Rendition(url: url, width: effectiveWidth(of: url, descriptor: descriptor,
                                                                                declaredWidth: declaredWidth)))
                }
            }
            for attribute in ["data-src", "src"] {
                let raw = (try? carrier.attr(attribute)) ?? ""
                guard !raw.isEmpty, let url = absolutize(raw, baseURL: baseURL), isPlainRaster(url) else { continue }
                let rendition = Rendition(url: url, width: effectiveWidth(of: url, descriptor: nil,
                                                                          declaredWidth: declaredWidth))
                candidates.append(rendition)
                if !isSource, imgSrc == nil { imgSrc = rendition }
            }
        }
        return (candidates, imgSrc)
    }

    /// A real http(s) raster URL: not a lazy-load `data:` placeholder, not WebP/AVIF/SVG/GIF.
    private static func isPlainRaster(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        return ext != "webp" && ext != "avif" && ext != "svg" && ext != "gif"
    }

    /// Splits a `srcset` value into (url, descriptor) pairs, following the HTML parsing rules: a
    /// candidate's URL is the run up to the next whitespace (so URLs that contain commas -- Cloudinary
    /// transforms, Guardian `precrop=40:21,offset-x50` -- stay whole), trailing commas are stripped
    /// from it, and its descriptor (`400w`, `2x`) runs to the next comma. That also handles lists
    /// written with NO space after the comma, e.g. Brightspot's `url 1x,url 2x`.
    private static func srcsetCandidates(_ value: String) -> [(String, String?)] {
        let chars = Array(value)
        func isSpace(_ c: Character) -> Bool { c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}" }
        var result: [(String, String?)] = []
        var i = 0
        while i < chars.count {
            while i < chars.count, isSpace(chars[i]) || chars[i] == "," { i += 1 }
            guard i < chars.count else { break }
            var url = ""
            while i < chars.count, !isSpace(chars[i]) { url.append(chars[i]); i += 1 }
            var descriptor: String? = nil
            if url.hasSuffix(",") {
                while url.hasSuffix(",") { url.removeLast() }
            } else {
                while i < chars.count, isSpace(chars[i]) { i += 1 }
                var raw = ""
                while i < chars.count, chars[i] != "," { raw.append(chars[i]); i += 1 }
                descriptor = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                    .first.map(String.init)
            }
            if !url.isEmpty { result.append((url, descriptor)) }
        }
        return result
    }

    private static func effectiveWidth(of url: URL, descriptor: String?, declaredWidth: Int) -> Int {
        if let descriptor = descriptor?.lowercased() {
            if descriptor.hasSuffix("w"), let w = Int(descriptor.dropLast()) { return w }
            if descriptor.hasSuffix("x"), let x = Double(descriptor.dropLast()), declaredWidth > 0 {
                return Int((Double(declaredWidth) * x).rounded())
            }
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ names: [String]) -> String? {
            items.first(where: { names.contains($0.name.lowercased()) })?.value
        }
        if let width = value(["width", "w"]).flatMap({ Int($0) }) {
            let dpr = value(["dpr"]).flatMap { Double($0) } ?? 1
            return Int((Double(width) * dpr).rounded())
        }
        if declaredWidth > 0 { return declaredWidth }
        // Last resort: the size baked into the URL itself (Brightspot `/resize/1486x991!/`, Jetpack
        // `?resize=1536,1024`).
        return resizeDimensions(of: url)?.width ?? 0
    }

    /// The final pixel size a resizing-proxy URL asks for: Brightspot's `/resize/<W>x<H>` path segment or
    /// a `?resize=<W>,<H>` query (WordPress/Jetpack). nil when the URL carries neither.
    private static func resizeDimensions(of url: URL) -> (width: Int, height: Int)? {
        if let range = url.path.range(of: "/resize/\\d+x\\d+", options: .regularExpression) {
            let parts = url.path[range].dropFirst("/resize/".count).split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 { return (w, h) }
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for name in ["resize", "fit"] {
            if let value = items.first(where: { $0.name == name })?.value {
                let parts = value.split(whereSeparator: { $0 == "," || $0 == "x" })
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 { return (w, h) }
            }
        }
        return nil
    }

    /// Renditions the page publishes as schema.org structured data: `ImageObject` entries (with their
    /// stated `width`) anywhere in the page's `application/ld+json` blocks. WBEZ and the Sun-Times list
    /// their uncropped 3:2 photo there at 1486x991, which the page's own `<img>` tags (16:9 crops) lack.
    private static func jsonLDImageRenditions(in doc: Document, baseURL: URL) -> [Rendition] {
        guard let scripts = try? doc.select("script[type=application/ld+json]") else { return [] }
        var found: [Rendition] = []
        func walk(_ node: Any) {
            if let array = node as? [Any] { array.forEach(walk); return }
            guard let dict = node as? [String: Any] else { return }
            if (dict["@type"] as? String) == "ImageObject", let raw = dict["url"] as? String,
               let url = absolutize(raw, baseURL: baseURL), isPlainRaster(url) {
                let stated = (dict["width"] as? NSNumber)?.intValue ?? Int((dict["width"] as? String) ?? "") ?? 0
                found.append(Rendition(url: url, width: stated > 0
                                        ? stated : effectiveWidth(of: url, descriptor: nil, declaredWidth: 0)))
            }
            dict.values.forEach(walk)
        }
        for script in scripts.array() {
            guard let text = try? script.data(), let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            walk(json)
        }
        return found
    }

    /// Two renditions are the same FRAMING when both state their final size and the aspect ratios agree
    /// within 3%; when either doesn't say, they are assumed compatible. Keeps a 3:2 feed hero from being
    /// swapped for a 16:9 crop of the same photo (WBEZ's page layout), which would change the composition.
    private static func sameFraming(_ a: URL, _ b: URL) -> Bool {
        guard let da = resizeDimensions(of: a), let db = resizeDimensions(of: b) else { return true }
        let ra = Double(da.width) / Double(da.height), rb = Double(db.width) / Double(db.height)
        return abs(ra - rb) / rb <= 0.03
    }

    /// "Same photograph": same host and either the same path or a shared long asset id (a path
    /// segment of 24+ characters containing a digit, extension stripped -- Guardian's 40-hex asset
    /// hash, BBC's UUID filename). Renditions of one photo differ only in size/crop segments. For
    /// resizing proxies that carry the original in a `url=` query parameter (Brightspot's `dims4`,
    /// used by Sun-Times/WBEZ/NPR) the ORIGINAL's host and path are what is compared.
    private static func samePhoto(_ a: URL, _ b: URL) -> Bool {
        guard let assetA = canonicalAsset(a), let assetB = canonicalAsset(b), assetA.host == assetB.host else {
            return false
        }
        if assetA.path == assetB.path { return true }
        return !assetTokens(path: assetA.path).isDisjoint(with: assetTokens(path: assetB.path))
    }

    private static func canonicalAsset(_ url: URL) -> (host: String, path: String)? {
        if let embedded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "url" })?.value,
           let inner = URL(string: embedded), let innerHost = inner.host {
            return (innerHost.lowercased(), inner.path)
        }
        guard let host = url.host else { return nil }
        return (host.lowercased(), url.path)
    }

    private static func assetTokens(path: String) -> Set<String> {
        var tokens = Set<String>()
        for segment in path.split(separator: "/") {
            var s = String(segment).lowercased()
            while let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) <= 5 {
                s = String(s[..<dot])
            }
            // A hash/UUID-like id: long, has a digit, and NO dots (a dotted segment is a host name such
            // as Jetpack's `bcc-newspack.s3.amazonaws.com`, which every image of a site shares).
            if s.count >= 24, !s.contains("."), s.contains(where: { $0.isNumber }) { tokens.insert(s) }
        }
        return tokens
    }

    // MARK: - Page rendition upgrade for FEED-TEXT sources (hero upgrade)
    //
    // Sources whose text arrives in the feed (Sun-Times, WBEZ: both Brightspot) never fetch the article
    // page, so their hero is whatever rendition the FEED carries -- 840 px wide for those two. The page
    // itself lists the same lead photo at 1680 px (`<img srcset="...840 1x,...1680 2x">`, signed
    // `dims4` URLs the publisher publishes). On an iPad, where a hero is drawn about 700 pt (1400 px)
    // wide, 840 px is visibly soft. The aggregator opts sources in (see
    // `EditionCompiler.pageHeroUpgradeSourceIDs`) and calls `upgradingHero` with the article page.
    //
    // Safety comes from IDENTITY, not position: only renditions of the SAME photograph as the feed's
    // hero (`samePhoto`) are ever considered, wherever on the page they sit, so a related-story
    // thumbnail or an ad image can never be promoted.

    /// `article` with its hero swapped for the page's best rendition OF THE SAME PHOTO (every `<img>`/
    /// `<picture>` on the page is searched; see `pickRendition` for the width rule), and only when that
    /// is wider than the width the current hero URL declares. The body's first image block (the feed's
    /// own copy of that photo) is dropped so it is not shown twice. nil = nothing to upgrade (no hero,
    /// the photo isn't on the page, or no gain).
    static func upgradingHero(of article: ExtractedArticle, fromPageHTML html: String,
                              pageURL: URL) -> ExtractedArticle? {
        guard let currentHero = article.heroImageURL, let doc = try? SwiftSoup.parse(html),
              let images = try? doc.select("img") else { return nil }

        var candidates: [Rendition] = []
        var imgSrc: Rendition?
        for img in images.array() {
            let found = renditionCandidates(forImage: img, baseURL: pageURL)
            let same = found.all.filter { samePhoto(currentHero, $0.url) && sameFraming(currentHero, $0.url) }
            guard !same.isEmpty else { continue }
            candidates.append(contentsOf: same)
            if imgSrc == nil { imgSrc = found.imgSrc.flatMap { candidate in same.contains { $0.url == candidate.url } ? candidate : nil } }
        }
        candidates.append(contentsOf: jsonLDImageRenditions(in: doc, baseURL: pageURL)
            .filter { samePhoto(currentHero, $0.url) && sameFraming(currentHero, $0.url) })
        // A candidate whose size the page doesn't state is never an "upgrade".
        guard let best = pickRendition(from: candidates, imgSrc: imgSrc), best.url != currentHero,
              best.width > 0 else { return nil }
        let currentWidth = declaredWidth(inURL: currentHero)
        if currentWidth > 0, best.width <= currentWidth { return nil }

        var blocks = article.bodyBlocks
        if let index = blocks.firstIndex(where: { $0.kind == .image }),
           let blockURL = blocks[index].imageURLString.flatMap({ URL(string: $0) }),
           samePhoto(blockURL, best.url) {
            blocks.remove(at: index)
        }
        return buildArticle(title: article.title, blocks: blocks, ogImageURL: best.url,
                            author: article.author, authorInstitution: article.authorInstitution,
                            url: article.url, publishedAt: article.publishedAt)
    }

    /// Pixel width a URL advertises for itself (`width`/`w` x `dpr`, else the baked-in resize size); 0
    /// when it says nothing.
    private static func declaredWidth(inURL url: URL) -> Int {
        effectiveWidth(of: url, descriptor: nil, declaredWidth: 0)
    }

    // MARK: - og:image

    private static func ogImageURL(in doc: Document, baseURL: URL) -> URL? {
        guard let matches = try? doc.select("meta[property=og:image]"), let meta = matches.first() else {
            return nil
        }
        guard let content = try? meta.attr("content"), !content.isEmpty else { return nil }
        return absolutize(content, baseURL: baseURL)
    }
}
