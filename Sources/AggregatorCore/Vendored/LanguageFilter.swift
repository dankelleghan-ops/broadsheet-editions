import Foundation
// v1.15 aggregator portability: NaturalLanguage does not exist on Linux (the GitHub Actions
// edition compiler -- see aggregator/README.md). The structural la-voz rule below is pure
// Foundation and ports as-is; the general NLLanguageRecognizer fallback is compiled out on
// platforms without NaturalLanguage (`#if canImport(NaturalLanguage)` blocks below). That is a
// deliberate fidelity tradeoff with no user-visible loss: the phone re-applies its FULL
// language filter (structural + ML fallback) on ingest anyway -- defense in depth. On every
// Apple platform `canImport(NaturalLanguage)` is true and this file behaves exactly as before.
// This file is vendored byte-for-byte into aggregator/Sources/AggregatorCore/Vendored/ by
// aggregator/sync-shared-sources.sh -- keep it portable or that sync breaks.
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// v1.12: language detection for `ArticleGate` (user report: Spanish-language articles were
/// reaching the daily stack -- Sun-Times syndicates La Voz Chicago, a Spanish-language
/// section, through its single "All" feed with no per-item feed category to key off).
///
/// **Two rules, checked in order.**
///
/// 1. **Structural (PRIMARY)** -- `isKnownNonEnglishURL`. Investigated live 2026-08-03 against
///    chicago.suntimes.com: the configured feed (`chicago.suntimes.com/rss/index.xml`, an
///    Atom "All" feed -- see `SourceCatalog`) carries no `<category>` tag and no separate feed
///    for La Voz content at all, but EVERY La Voz article's URL carries a literal `la-voz` path
///    component (confirmed against chicago.suntimes.com/la-voz's real article list, e.g.
///    `.../la-voz/2026/07/30/gobernador-de-illinois-convierte-en-ley-la-prohibicion-de-telefonos-celulares-en-las-escuelas`
///    -- the exact article reported as evidence). This is fast (a path-component check,
///    no ML, no allocation beyond the URL's own `pathComponents`) and deterministic (a La Voz
///    URL is never ambiguous), so it's checked first and short-circuits the general fallback
///    below entirely when it fires.
///
/// 2. **General (FALLBACK)** -- `dominantNonEnglishHypothesis`. Every other source (and any
///    future non-English content with no structural marker of its own) is caught by on-device
///    `NLLanguageRecognizer` over the title + first ~2 paragraphs. Deliberately conservative:
///    only rejects when the dominant hypothesis is NOT English AND clears
///    `nonEnglishConfidenceThreshold` (0.8) -- ambiguous, short, or mixed-language text (an
///    English article quoting a Spanish phrase, a short title alone) must never false-positive,
///    so "no confident hypothesis at all" always means PASS, never reject-on-low-confidence.
enum LanguageFilter {

    /// Confidence floor for the general `NLLanguageRecognizer` fallback. Chosen high
    /// deliberately (spec: "so mixed quotes/names never false-positive") -- an English article
    /// that merely quotes a Spanish phrase in the title ("'Sí se puede': Chicago marchers
    /// rally") must survive, and a real Spanish-language article clears this with enormous
    /// margin (NLLanguageRecognizer typically reports > 0.95 confidence on a few full Spanish
    /// sentences), so there's no real tension between "high enough to never false-positive on a
    /// quote" and "low enough to reliably catch a genuine Spanish article."
    static let nonEnglishConfidenceThreshold = 0.8

    /// PRIMARY structural rule (see this type's doc comment): true when `url`'s path contains a
    /// `la-voz` COMPONENT (not merely a substring -- `pathComponents`, not `.contains("la-voz")`
    /// on the raw string -- so this can never accidentally fire on some unrelated segment that
    /// happens to contain those letters). `nil` (no URL available, e.g. an older stored article
    /// or a test fixture that didn't set one) is never a match; the general fallback below
    /// covers that case instead.
    static func isKnownNonEnglishURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.pathComponents.contains("la-voz")
    }

    /// GENERAL fallback: the dominant NON-English `(language, confidence)` for `title` + the
    /// first `sampleParagraphLimit` paragraph blocks, IF -- and only if -- it clears
    /// `nonEnglishConfidenceThreshold`. Returns `nil` for English text, empty/whitespace-only
    /// text, or any hypothesis that doesn't clear the confidence floor (never reject on low
    /// confidence, per spec).
    private static let sampleParagraphLimit = 2

    #if canImport(NaturalLanguage)
    static func dominantNonEnglishHypothesis(
        title: String, bodyBlocks: [BodyBlock]
    ) -> (language: NLLanguage, confidence: Double)? {
        let sampleParagraphs = bodyBlocks
            .filter { $0.kind == .paragraph }
            .prefix(sampleParagraphLimit)
            .compactMap { $0.text }
        let sample = ([title] + sampleParagraphs)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        // withMaximum: 1 -- we only ever care about the single dominant hypothesis and its own
        // confidence, not a ranked list.
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else {
            return nil
        }
        guard language != .english, confidence >= nonEnglishConfidenceThreshold else { return nil }
        return (language, confidence)
    }
    #endif

    /// Combined rule, gate-ready: `nil` to pass, or a human-readable rejection reason string
    /// (`ArticleGate` folds this straight into its own `.fail(reason:)`, matching every other
    /// rule in that file). Reason format for the general fallback matches the spec's log-line
    /// example verbatim (`non-English (es 0.97)` -- BCP-47 language code + confidence to 2
    /// decimal places); the structural path names itself explicitly since it has no ML
    /// confidence score to report.
    static func nonEnglishRejectionReason(title: String, bodyBlocks: [BodyBlock], url: URL?) -> String? {
        if isKnownNonEnglishURL(url) {
            return "non-English (structural: la-voz URL path)"
        }
        #if canImport(NaturalLanguage)
        guard let (language, confidence) = dominantNonEnglishHypothesis(title: title, bodyBlocks: bodyBlocks) else {
            return nil
        }
        let confidenceText = String(format: "%.2f", confidence)
        return "non-English (\(language.rawValue) \(confidenceText))"
        #else
        // No NaturalLanguage on this platform (Linux edition compiler): the structural rule
        // above is the only server-side check; the phone's own full filter re-runs on ingest.
        return nil
        #endif
    }

    /// Plain `Bool` convenience over `nonEnglishRejectionReason` for callers that only need the
    /// yes/no answer, not the reason string -- `LanguageBackfill` (removing already-stored
    /// non-English rows) is the sole caller; `ArticleGate` uses `nonEnglishRejectionReason`
    /// directly since it needs the reason text for its `.fail` case.
    static func isNonEnglish(title: String, bodyBlocks: [BodyBlock], url: URL?) -> Bool {
        nonEnglishRejectionReason(title: title, bodyBlocks: bodyBlocks, url: url) != nil
    }
}
