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
                                          url: URL? = nil) -> ExtractedArticle {
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
                                 url: url)
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

        let ogImageURL = Self.ogImageURL(in: doc, baseURL: articleURL)

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
                                  author: author, authorInstitution: authorInstitution, url: articleURL)
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

    // MARK: - og:image

    private static func ogImageURL(in doc: Document, baseURL: URL) -> URL? {
        guard let matches = try? doc.select("meta[property=og:image]"), let meta = matches.first() else {
            return nil
        }
        guard let content = try? meta.attr("content"), !content.isEmpty else { return nil }
        return absolutize(content, baseURL: baseURL)
    }
}
