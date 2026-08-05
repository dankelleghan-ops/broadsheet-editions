import XCTest
@testable import AggregatorCore

/// Spot-checks that the VENDORED gate + language filter behave exactly like the app's --
/// exercising the copies this package actually compiles, against the same rules the app's own
/// ArticleGateTests/LanguageFilterTests pin.
final class GateAndLanguageParityTests: XCTestCase {

    private func paragraph(_ text: String) -> BodyBlock {
        BodyBlock(kind: .paragraph, text: text, imageURLString: nil, caption: nil, credit: nil)
    }

    private func proseArticle(url: URL? = nil) -> ExtractedArticle {
        let long = String(repeating: "Real reported prose with actual sentences in it. ", count: 6)
        return ExtractedArticle(title: "A headline", byline: nil,
                                bodyBlocks: [paragraph(long), paragraph(long), paragraph(long)],
                                heroImageURL: nil, allImageURLs: [], url: url)
    }

    func testGatePassesRealProse() {
        XCTAssertEqual(ArticleGate.evaluate(proseArticle(), englishOnly: false), .pass)
    }

    func testGateRejectsThinBody() {
        let thin = ExtractedArticle(title: "T", byline: nil,
                                    bodyBlocks: [paragraph("Too short."), paragraph("Also short.")],
                                    heroImageURL: nil, allImageURLs: [])
        guard case .fail(let reason) = ArticleGate.evaluate(thin, englishOnly: false) else {
            return XCTFail("thin body must fail the gate")
        }
        XCTAssertTrue(reason.contains("paragraph blocks"), reason)
    }

    func testGateRejectsPaywallMarker() {
        let long = String(repeating: "Words repeated to clear the six hundred char floor. ", count: 8)
        let article = ExtractedArticle(
            title: "T", byline: nil,
            bodyBlocks: [paragraph(long), paragraph(long), paragraph("Subscribe to continue reading this story.")],
            heroImageURL: nil, allImageURLs: [])
        guard case .fail(let reason) = ArticleGate.evaluate(article, englishOnly: false) else {
            return XCTFail("paywall marker must fail the gate")
        }
        XCTAssertTrue(reason.contains("paywall"), reason)
    }

    func testGateRequiresAttributionWhenFlagged() {
        var article = proseArticle()
        article.author = nil
        article.authorInstitution = nil
        guard case .fail(let reason) = ArticleGate.evaluate(article, requiresAttribution: true,
                                                           englishOnly: false) else {
            return XCTFail("attribution-required source with no byline must fail")
        }
        XCTAssertTrue(reason.contains("attribution"), reason)

        article.author = "Jane Scholar"
        XCTAssertEqual(ArticleGate.evaluate(article, requiresAttribution: true, englishOnly: false), .pass)
    }

    /// The structural la-voz rule is pure Foundation and runs on EVERY platform (it is the
    /// only server-side language rule on Linux).
    func testLanguageFilterStructuralLaVozRule() {
        let laVoz = URL(string: "https://chicago.suntimes.com/la-voz/2026/07/30/gobernador-de-illinois")!
        XCTAssertEqual(
            LanguageFilter.nonEnglishRejectionReason(title: "Titular", bodyBlocks: [], url: laVoz),
            "non-English (structural: la-voz URL path)"
        )
        let english = URL(string: "https://chicago.suntimes.com/city-hall/2026/07/30/some-story")!
        XCTAssertNil(LanguageFilter.nonEnglishRejectionReason(
            title: "An English headline", bodyBlocks: [], url: english))
    }

    func testGateAppliesLanguageFilterWhenEnglishOnly() {
        let laVoz = URL(string: "https://chicago.suntimes.com/la-voz/2026/07/30/gobernador")!
        let article = proseArticle(url: laVoz)
        guard case .fail(let reason) = ArticleGate.evaluate(article, englishOnly: true) else {
            return XCTFail("la-voz URL must fail with englishOnly")
        }
        XCTAssertTrue(reason.contains("la-voz"), reason)
        // Same article, filter off: passes.
        XCTAssertEqual(ArticleGate.evaluate(article, englishOnly: false), .pass)
    }

    #if canImport(NaturalLanguage)
    /// macOS `swift test` also exercises the ML fallback the phone uses; on Linux this branch
    /// is compiled out (the phone re-filters on ingest).
    func testLanguageFilterMLFallbackCatchesSpanishProse() {
        let spanish = paragraph(
            "El gobernador de Illinois convirtió en ley la prohibición de teléfonos celulares en las escuelas públicas del estado."
        )
        let reason = LanguageFilter.nonEnglishRejectionReason(
            title: "Gobernador convierte en ley la prohibición",
            bodyBlocks: [spanish, spanish], url: nil)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("es") == true, reason ?? "nil")
    }
    #endif
}
