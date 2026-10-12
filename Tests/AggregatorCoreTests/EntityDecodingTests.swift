import XCTest
@testable import AggregatorCore

/// The vendored decoder is what the edition compiler runs on Linux, so the compiler decodes a feed's
/// entities exactly as the app does. A PBS NewsHour headline ("El Ni&ntilde;o's storm-killer winds ...")
/// reached an iPad undecoded; these pin the decoder this package actually compiles.
final class EntityDecodingTests: XCTestCase {

    func testReportedHeadlineDecodes() {
        XCTAssertEqual(
            FeedText.cleanTitle("El Ni&ntilde;o's storm-killer winds and climate's warming waters in fight over future of Hurricane Isaias"),
            "El Niño's storm-killer winds and climate's warming waters in fight over future of Hurricane Isaias")
    }

    func testNamesTheOldFortyThreeNameListMissedNowDecode() {
        let cases: [(String, String)] = [
            ("&Ntilde;and&uacute;", "Ñandú"), ("&ecirc;tre", "être"), ("&agrave; la carte", "à la carte"),
            ("Stra&szlig;e", "Straße"), ("&iquest;Qu&eacute;?", "¿Qué?"), ("&Eacute;&eacute;", "Éé"),
            ("&THORN;&thorn;", "Þþ"), ("&hearts; &check; &starf;", "♥ ✓ ★"), ("&rarr; &hArr;", "→ ⇔"),
            ("&NotEqualTilde;", "\u{2242}\u{0338}"), ("&fjlig;", "fj"), ("&Alpha;&omega;", "Αω")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(FeedText.cleanTitle(raw), expected, raw)
        }
    }

    func testDoubleEscapedAndNumericForms() {
        XCTAssertEqual(FeedText.cleanTitle("El Ni&amp;ntilde;o"), "El Niño")
        XCTAssertEqual(FeedText.cleanTitle("Trump&#8217;s &#x27;deal&#x27; &#xF1; &#241;"), "Trump\u{2019}s 'deal' ñ ñ")
        XCTAssertEqual(FeedText.cleanTitle("Tom&nbsp;&amp;&nbsp;Jerry"), "Tom & Jerry")
    }

    /// 0x80-0x9F as a numeric reference is the Windows-1252 character (HTML standard), not a control code.
    func testC1NumericReferencesAreWindows1252Characters() {
        XCTAssertEqual(FeedText.cleanTitle("&#146;"), "\u{2019}")
        XCTAssertEqual(FeedText.cleanTitle("&#x96;"), "\u{2013}")
        XCTAssertEqual(FeedText.cleanTitle("&#150;"), "\u{2013}")
        XCTAssertEqual(FeedText.cleanTitle("&#128;"), "\u{20AC}")
        XCTAssertEqual(FeedText.cleanField("Don&#146;t &#151; &#147;ok&#148;"), "Don\u{2019}t \u{2014} \u{201C}ok\u{201D}")
        // No Windows-1252 character for these: unchanged from before.
        XCTAssertEqual(FeedText.cleanField("&#129;"), "\u{0081}")
        XCTAssertEqual(FeedText.cleanField("&#141;&#143;&#144;&#157;"), "\u{008D}\u{008F}\u{0090}\u{009D}")
        // Neighbours of the range.
        XCTAssertEqual(FeedText.cleanField("&#127;&#160;"), "\u{007F}\u{00A0}")
    }

    func testUnknownAndMalformedSequencesStayAsWritten() {
        for text in ["AT&T;", "&notanentity;", "R&D", "&", "&amp", "&#0;", "&#xD800;", "&#1114112;", "&#99999999999999999999;"] {
            XCTAssertEqual(FeedText.cleanTitle(text), text, text)
        }
    }

    func testCleaningTwiceChangesNothing() {
        for text in ["El Ni&ntilde;o &amp; Q&A", "<em>Em</em> head &Ntilde;", "Plain", "AT&T; Staff", "Stocks fall <5%"] {
            let once = FeedText.cleanTitle(text)
            XCTAssertEqual(FeedText.cleanTitle(once), once, text)
        }
    }

    /// Both ways a feed can carry the PBS headline through the real parser the compiler uses.
    func testParserDecodesTitleAuthorAndSummary() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>T</title>
        <item><title><![CDATA[El Ni&ntilde;o's storm-killer winds]]></title><link>https://example.org/a</link><guid>g1</guid>
        <dc:creator>Ren&amp;ecirc; Pe&amp;Ntilde;a</dc:creator><description>&amp;iquest;Qu&amp;eacute;? Stra&amp;szlig;e</description></item>
        <item><title>El Ni&amp;ntilde;o&amp;rsquo;s storm-killer winds</title><link>https://example.org/b</link><guid>g2</guid></item>
        </channel></rss>
        """
        let endpoint = FeedEndpoint(url: URL(string: "https://example.org/feed")!, defaultCategory: .us)
        let items = try FeedParser().parse(data: Data(xml.utf8), endpoint: endpoint)
        XCTAssertEqual(items[0].title, "El Niño's storm-killer winds")
        XCTAssertEqual(items[0].author, "Renê PeÑa")
        XCTAssertEqual(items[0].summary, "¿Qué? Straße")
        XCTAssertEqual(items[1].title, "El Niño\u{2019}s storm-killer winds")
    }
}
