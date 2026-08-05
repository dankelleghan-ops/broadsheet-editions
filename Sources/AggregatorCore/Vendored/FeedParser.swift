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
        _ = endpoint // reserved for future per-feed parsing hints; categorization happens in Categorizer
        let delegate = FeedXMLDelegate()
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

    private func resetItemState() {
        guid = nil
        link = nil
        title = nil
        summary = nil
        publishedString = nil
        updatedString = nil
        categories = []
        contentHTML = nil
        contentType = nil
        imageURLs = []
        authorName = nil
        inAuthorTag = false
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
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
            }
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
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inItem else { return }
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
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
            title = decodeHTMLEntities(text)
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
        case "updated":
            updatedString = text
        case "description":
            summary = decodeHTMLEntities(text)
        case "summary":
            if isAtom { summary = decodeHTMLEntities(text) }
        case "content:encoded":
            contentHTML = text
        case "content":
            if isAtom && contentType == "html" { contentHTML = text }
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
            publishedAt: parseDate(publishedString ?? updatedString),
            feedCategories: categories,
            contentHTML: (contentHTML?.isEmpty ?? true) ? nil : contentHTML,
            imageURLs: imageURLs,
            author: (authorName?.isEmpty ?? true) ? nil : authorName
        )
        items.append(item)
    }
}

private func decodeHTMLEntities(_ string: String) -> String {
    guard string.contains("&") else { return string }
    var result = string
    let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}",
        "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
        "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}", "&hellip;": "\u{2026}"
    ]
    for (entity, replacement) in namedEntities {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }
    while let range = result.range(of: "&#[0-9]+;", options: .regularExpression) {
        let match = String(result[range])
        let digits = match.dropFirst(2).dropLast(1)
        guard let scalarValue = UInt32(digits), let scalar = Unicode.Scalar(scalarValue) else { break }
        result.replaceSubrange(range, with: String(Character(scalar)))
    }
    while let range = result.range(of: "&#x[0-9A-Fa-f]+;", options: .regularExpression) {
        let match = String(result[range])
        let digits = match.dropFirst(3).dropLast(1)
        guard let scalarValue = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(scalarValue) else { break }
        result.replaceSubrange(range, with: String(Character(scalar)))
    }
    return result
}

private func parseDate(_ string: String?) -> Date? {
    guard let string = string, !string.isEmpty else { return nil }

    let rfc822 = DateFormatter()
    rfc822.locale = Locale(identifier: "en_US_POSIX")
    rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = rfc822.date(from: string) { return date }

    let iso8601 = ISO8601DateFormatter()
    iso8601.formatOptions = [.withInternetDateTime]
    return iso8601.date(from: string)
}
