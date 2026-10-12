import Foundation
// v1.15 aggregator portability: on Linux (the GitHub Actions edition compiler -- see
// aggregator/README.md), Foundation's XMLParser lives in the separate FoundationXML module.
// `canImport(FoundationXML)` is false on every Apple platform, so this compiles to nothing in
// the app and changes no iOS behavior. This file is vendored byte-for-byte into
// aggregator/Sources/AggregatorCore/Vendored/ by aggregator/sync-shared-sources.sh -- keep it
// portable (Foundation-only, no UIKit/SwiftUI) or that sync breaks.
#if canImport(FoundationXML)
import FoundationXML
#endif

enum FeedParserError: Error, Equatable {
    case malformedXML(String)
}

final class FeedParser {
    func parse(data: Data, endpoint: FeedEndpoint) throws -> [FeedItem] {
        // The endpoint's only parsing hint is the zone its zone-less timestamps are written in
        // (`FeedEndpoint.zonelessDatesTimeZone`); categorization happens in Categorizer.
        let delegate = FeedXMLDelegate(zonelessTimeZone: endpoint.zonelessDatesTimeZone)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.shouldProcessNamespaces = false
        guard xmlParser.parse() else {
            let message = xmlParser.parserError?.localizedDescription ?? "unknown XML parsing error"
            throw FeedParserError.malformedXML(message)
        }
        return delegate.items
    }

    /// v1.3.1 item 7 (NBC News): some sources' `<link>` can point somewhere other than the real
    /// article -- confirmed live 2026-07-27 on NBC News's feed (video pages under a `<link>`
    /// whose sibling `<guid isPermaLink="true">` is itself the genuine article URL). When
    /// `SourceConfig.preferGUIDAsURL` is set, this swaps each item's `.url` for its `.guid`
    /// whenever the guid parses as an absolute http(s) URL, leaving every other item (and every
    /// source with the flag unset) untouched -- an item whose guid is a non-URL identifier
    /// (a UUID, a slug) is left pointing at its original `.link` URL exactly as before.
    static func applyGUIDAsURLPreference(to items: [FeedItem], enabled: Bool) -> [FeedItem] {
        guard enabled else { return items }
        return items.map { item in
            guard let guidURL = URL(string: item.guid),
                  let scheme = guidURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                return item
            }
            return FeedItem(
                guid: item.guid, url: guidURL, title: item.title, summary: item.summary,
                publishedAt: item.publishedAt, feedCategories: item.feedCategories,
                contentHTML: item.contentHTML, imageURLs: item.imageURLs, author: item.author
            )
        }
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [FeedItem] = []

    private var isAtom = false
    private var inItem = false
    private var currentText = ""

    private var guid: String?
    private var link: String?
    private var title: String?
    private var summary: String?
    private var publishedString: String?
    private var updatedString: String?
    /// `<dc:date>` -- the Dublin Core date some RSS feeds use INSTEAD of `<pubDate>`; a fallback only.
    private var dcDateString: String?
    private let zonelessTimeZone: TimeZone?

    init(zonelessTimeZone: TimeZone?) {
        self.zonelessTimeZone = zonelessTimeZone
        super.init()
    }
    private var categories: [String] = []
    private var contentHTML: String?
    private var contentType: String?
    private var imageURLs: [URL] = []
    // v1.8: feed-supplied byline -- Atom's <author><name> or RSS's <dc:creator> (see
    // FeedParser.parse's doc comment / FeedItem.author). `inAuthorTag` is only ever set true
    // between an Atom <author> start/end pair, so a bare RSS <author> (an email address, a
    // different convention this app doesn't use) never falls into the <name> capture branch.
    private var authorName: String?
    private var inAuthorTag = false

    // MARK: nested markup inside a content element
    //
    // Chicago Sun-Times and WBEZ (Brightspot) serve `<content type="html">` as a MIX: the lead photo
    // is a raw, unescaped `<img .../>` XML child, then the story is ESCAPED markup text
    // (`&lt;p&gt;...`). XMLParser reports the `<img>` as an element, and this delegate used to clear
    // its text buffer at every element start -- so the lead `<img>` (and any text before it) vanished.
    // Measured on the live feeds 2026-10-11: 45 of 54 Sun-Times and 8 of 19 WBEZ items had no hero
    // photo at all; the rest took whatever small (490x275) photo was embedded mid-body.
    //
    // While inside a content element, nested elements are now SERIALIZED back into the content text
    // instead of resetting it: `<img src=".." alt=".."/>` for void tags, `<b>` ... `</b>` otherwise,
    // with attribute values and nested text re-escaped. Only content elements are affected
    // (`content` of an html Atom entry, `content:encoded`); every shape that already worked (CDATA,
    // fully escaped markup) never produces a nested element and is byte-identical to before.
    private var inContentElement = false
    private var nestedDepth = 0

    private static let voidElements: Set<String> = [
        "img", "br", "hr", "source", "input", "meta", "link", "area", "base", "col", "embed", "param", "track", "wbr"
    ]

    private static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func startTag(_ name: String, _ attributes: [String: String]) -> String {
        var tag = "<" + name
        for key in attributes.keys.sorted() {
            tag += " \(key)=\"\(escapeAttribute(attributes[key] ?? ""))\""
        }
        return tag + (voidElements.contains(name.lowercased()) ? "/>" : ">")
    }

    private func resetItemState() {
        inContentElement = false
        nestedDepth = 0
        guid = nil
        link = nil
        title = nil
        summary = nil
        publishedString = nil
        updatedString = nil
        dcDateString = nil
        categories = []
        contentHTML = nil
        contentType = nil
        imageURLs = []
        authorName = nil
        inAuthorTag = false
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // Nested markup inside a content element: keep it (see "nested markup" above).
        if inItem, inContentElement {
            nestedDepth += 1
            currentText += Self.startTag(elementName, attributeDict)
            return
        }

        currentText = ""

        if elementName == "feed" { isAtom = true }

        if elementName == "item" || elementName == "entry" {
            inItem = true
            resetItemState()
            return
        }

        guard inItem else { return }

        switch elementName {
        case "enclosure":
            if let urlString = attributeDict["url"], let type = attributeDict["type"], type.hasPrefix("image/"), let url = URL(string: urlString) {
                imageURLs.append(url)
            }
        case "media:content":
            if let urlString = attributeDict["url"], let url = URL(string: urlString) {
                let medium = attributeDict["medium"]
                let type = attributeDict["type"]
                if medium == "image" || (type?.hasPrefix("image/") ?? false) {
                    imageURLs.append(url)
                }
            }
        case "media:thumbnail":
            if let urlString = attributeDict["url"], let url = URL(string: urlString) {
                imageURLs.append(url)
            }
        case "link":
            if isAtom {
                let rel = attributeDict["rel"] ?? "alternate"
                if rel == "alternate", let href = attributeDict["href"] {
                    link = href
                }
            }
        case "category":
            if isAtom, let term = attributeDict["term"] {
                categories.append(term)
            }
        case "content":
            if isAtom {
                contentType = attributeDict["type"]
                inContentElement = (contentType == "html")
            }
        case "content:encoded":
            inContentElement = true
        case "author":
            // v1.8: only Atom's <author><name> convention is handled -- see the `authorName`
            // doc comment above for why a bare RSS <author> (email-address convention) is
            // deliberately left alone.
            if isAtom { inAuthorTag = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        // Text INSIDE a nested element is real text of that element, so it is re-escaped; text directly
        // in the content element is already markup text (the escaped-HTML shape) and is kept as is.
        currentText += nestedDepth > 0 ? Self.escapeText(string) : string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inItem else { return }
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentText += nestedDepth > 0 ? Self.escapeText(string) : string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        // End of a nested element inside a content element: close it in the text (void tags were
        // already self-closed) and keep accumulating -- no buffer reset.
        if inItem, inContentElement, nestedDepth > 0 {
            nestedDepth -= 1
            if !Self.voidElements.contains(elementName.lowercased()) {
                currentText += "</\(elementName)>"
            }
            return
        }

        defer { currentText = "" }

        if elementName == "item" || elementName == "entry" {
            finalizeItem()
            inItem = false
            return
        }

        guard inItem else { return }

        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title":
            title = FeedText.cleanTitle(text)
        case "guid":
            guid = text
        case "id":
            if isAtom { guid = text }
        case "link":
            if !isAtom { link = text }
        case "pubDate":
            publishedString = text
        case "published":
            publishedString = text
        case "updated", "updateDate":
            // `updateDate` is NBC 5's "modified" stamp (the page's `dateModified`); like Atom's
            // `updated` it is only ever a fallback -- the ORIGINAL publish time wins.
            updatedString = text
        case "dc:date":
            dcDateString = text
        case "description":
            summary = decodeHTMLEntities(text)
        case "summary":
            if isAtom { summary = decodeHTMLEntities(text) }
        case "content:encoded":
            contentHTML = text
            inContentElement = false
        case "content":
            if isAtom && contentType == "html" { contentHTML = text }
            inContentElement = false
        case "category":
            if !isAtom, !text.isEmpty { categories.append(text) }
        case "name":
            // v1.8: Atom <author><name> -- see the `authorName` doc comment above.
            if inAuthorTag { authorName = decodeHTMLEntities(text) }
        case "author":
            if isAtom { inAuthorTag = false }
        case "dc:creator":
            // v1.8: RSS's namespaced creator element -- appears literally as "dc:creator" here
            // because `shouldProcessNamespaces` is false (same convention "media:content" and
            // "content:encoded" already rely on above).
            authorName = decodeHTMLEntities(text)
        default:
            break
        }
    }

    private func finalizeItem() {
        guard let t = title, let linkString = link, let url = URL(string: linkString) else {
            return
        }
        let resolvedGUID = (guid?.isEmpty == false) ? guid! : linkString
        let item = FeedItem(
            guid: resolvedGUID,
            url: url,
            title: t,
            summary: (summary?.isEmpty ?? true) ? nil : summary,
            // Original publish time first, then Dublin Core, then "modified" -- each tried on its own so
            // an element that is present but in a format we cannot read falls through to the next.
            publishedAt: FeedDates.parse(publishedString, zonelessTimeZone: zonelessTimeZone)
                ?? FeedDates.parse(dcDateString, zonelessTimeZone: zonelessTimeZone)
                ?? FeedDates.parse(updatedString, zonelessTimeZone: zonelessTimeZone),
            feedCategories: categories,
            contentHTML: (contentHTML?.isEmpty ?? true) ? nil : contentHTML,
            imageURLs: imageURLs,
            author: (authorName?.isEmpty ?? true) ? nil : authorName
        )
        items.append(item)
    }
}

/// Entity decoding in ONE pass (each `&...;` is replaced once and never re-scanned), so a
/// double-escaped `&amp;lt;` becomes the text `&lt;`, not a `<`. The previous implementation replaced
/// the named entities in dictionary order, which made that outcome depend on hash order. Unknown
/// or invalid entities are left exactly as written.
private func decodeHTMLEntities(_ string: String) -> String {
    guard string.contains("&") else { return string }
    let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
        "rdquo": "\u{201D}", "ldquo": "\u{201C}", "hellip": "\u{2026}", "bull": "\u{2022}",
        "middot": "\u{00B7}", "trade": "\u{2122}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "deg": "\u{00B0}", "euro": "\u{20AC}", "pound": "\u{00A3}", "cent": "\u{00A2}", "yen": "\u{00A5}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "frac12": "\u{00BD}", "frac14": "\u{00BC}",
        "eacute": "\u{00E9}", "egrave": "\u{00E8}", "aacute": "\u{00E1}", "iacute": "\u{00ED}",
        "oacute": "\u{00F3}", "uacute": "\u{00FA}", "ntilde": "\u{00F1}", "uuml": "\u{00FC}",
        "ouml": "\u{00F6}", "auml": "\u{00E4}", "ccedil": "\u{00E7}", "Eacute": "\u{00C9}"
    ]
    guard let regex = try? NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);") else {
        return string
    }
    let ns = string as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        cursor = match.range.location + match.range.length
        let body = ns.substring(with: match.range(at: 1))
        var replacement: String?
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else if body.hasPrefix("#") {
            replacement = UInt32(body.dropFirst(1)).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else {
            replacement = named[body]
        }
        result += replacement ?? ns.substring(with: match.range)
    }
    result += ns.substring(from: cursor)
    return result
}

/// Text hygiene for FEED-SUPPLIED TITLES (never the article body, which keeps its markup for
/// `ContentExtractor`). Some feeds deliver a headline with inline markup -- Slate's
/// `<![CDATA[<em>30 Rock </em>Once Seemed ...]]>` reached the screen as literal `<em>` tags -- and
/// others with entities (`&#8217;`, `&#x27;`, `&nbsp;`).
enum FeedText {
    /// Strips inline tags and comments, decodes entities (named, decimal, hex), collapses runs of
    /// whitespace, trims. Tag removal runs BEFORE entity decoding, so a decoded `&lt;` can never
    /// create a tag; a further pass (at most three) handles a double-escaped title such as
    /// `&amp;lt;em&amp;gt;`. A bare `<` that does not start a tag (`Stocks fall <5%`) is left alone.
    static func cleanTitle(_ raw: String) -> String {
        var text = raw
        for _ in 0..<3 {
            let stripped = text
                .replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
                .replacingOccurrences(of: "</?[A-Za-z][A-Za-z0-9:-]*(?:\\s[^<>]*)?/?>", with: "", options: .regularExpression)
            let decoded = decodeHTMLEntities(stripped)
            if decoded == text { break }
            text = decoded
            if !text.contains("<") && !text.contains("&") { break }
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Feed and page timestamp parsing. Reads the RFC 822 family (with or without weekday or seconds, numeric
/// or named zone), ISO 8601 with or without fractional seconds and with `+0500` or `+05:00` offsets
/// (Sun-Times and WBEZ write `2026-10-11T18:47:41.046-05:00`, which the old parser rejected), and --
/// ONLY when the caller names the feed's zone -- zone-less stamps such as NBC 5's
/// `Sun, Oct 11 2026 04:04:04 PM`. Anything it cannot read with certainty is nil, never a guess.
enum FeedDates {
    static func parse(_ string: String?, zonelessTimeZone: TimeZone? = nil) -> Date? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        if raw.range(of: "^\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}", options: .regularExpression) != nil {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: raw) { return date }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ssZ"] {
                if let date = formatter(format).date(from: raw) { return date }
            }
            if let zone = zonelessTimeZone {
                for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
                    if let date = formatter(format, zone: zone).date(from: raw) { return date }
                }
            }
            return nil
        }

        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss zzz",
                       "EEE, dd MMM yyyy HH:mm zzz", "EEE, dd MMM yyyy HH:mm Z"] {
            if let date = formatter(format).date(from: raw) { return date }
        }
        if let zone = zonelessTimeZone {
            for format in ["EEE, MMM dd yyyy hh:mm:ss a", "EEE, dd MMM yyyy HH:mm:ss", "EEE, MMM dd yyyy HH:mm:ss"] {
                if let date = formatter(format, zone: zone).date(from: raw) { return date }
            }
        }
        return nil
    }

    private static func formatter(_ format: String, zone: TimeZone? = nil) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        if let zone { f.timeZone = zone }
        return f
    }
}
