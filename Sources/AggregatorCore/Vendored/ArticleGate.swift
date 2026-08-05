import Foundation

enum GateResult: Equatable {
    case pass
    case fail(reason: String)
}

enum ArticleGate {
    private static let paywallMarkers = [
        "subscribe to continue",
        "sign in to read",
        "subscription required",
        "create a free account to"
    ]

    /// `requiresAttribution` (v1.8, spec item 3): true only for sources whose licence requires a
    /// visible author/institution credit (`SourceConfig.requiresAttribution` -- The Conversation's
    /// CC BY-ND 4.0). Defaults to `false` so every pre-v1.8 call site (every test above, and any
    /// future one that doesn't pass it) keeps its exact prior behavior unchanged. When `true`,
    /// this is an ADDITIONAL gate on top of every existing shape/length rule below, not a
    /// replacement for them -- an article with a perfectly good byline still has to clear the
    /// ordinary floors too. Matches this app's existing reject-rather-than-ship-something-wrong
    /// discipline: an article this app cannot credit under its source's licence terms must never
    /// be ingested at all, not ingested-and-silently-uncredited.
    /// `englishOnly` (v1.12): true rejects an article whose dominant language is confidently NOT
    /// English -- see `LanguageFilter`'s doc comment for the two-tier structural-then-general
    /// rule. Defaults to the LIVE `Prefs.shared.englishOnlyArticles` value, re-evaluated at every
    /// call site on every call (Swift default-argument expressions are evaluated fresh at the
    /// call site, not memoized -- same trick `RefreshCoordinator`'s `maxPerDayOverride` closure
    /// achieves explicitly elsewhere in this codebase) -- this is what lets Settings' "English-
    /// only articles" toggle take effect on the very next gate call with zero changes needed at
    /// `ArticleStore.selectAndDownload`'s existing 2-arg call site (`ArticleGate` is this
    /// release's sole insertion point; `ArticleStore.swift` itself is owned by a concurrent
    /// release and must not be touched -- see `.superpowers/sdd/v1.12-language-report.md`).
    /// Turning the toggle off means this parameter evaluates to `false` and `LanguageFilter` is
    /// never even invoked -- zero detection cost, per spec.
    static func evaluate(_ article: ExtractedArticle, requiresAttribution: Bool = false,
                          englishOnly: Bool = Prefs.shared.englishOnlyArticles) -> GateResult {
        if requiresAttribution, article.author == nil, article.authorInstitution == nil {
            return .fail(reason: "requires attribution but no author or institution could be extracted")
        }

        let paragraphs = article.bodyBlocks.filter { $0.kind == .paragraph }

        guard paragraphs.count >= 3 else {
            return .fail(reason: "only \(paragraphs.count) paragraph blocks, need >= 3")
        }

        let combinedText = paragraphs.compactMap { $0.text }.joined(separator: " ")
        guard combinedText.count >= 600 else {
            return .fail(reason: "only \(combinedText.count) paragraph chars, need >= 600")
        }

        // v1.3.3 fix D (reader-extraction-investigation.md §2c/§6c): the floors above already
        // existed specifically to reject thin extractions, but a body assembled from furniture
        // paragraphs scattered around a page (site tagline, author bios) can still clear both --
        // the Chicago Reader "quantum crossroads" PDF-zine article's 5 furniture paragraphs
        // totaled 734 chars, comfortably over 600. Shape catches what size alone can't: real
        // prose has an actual passage somewhere (a run of 2+ consecutive paragraph blocks with
        // no heading between them -- furniture is heading-separated, each paragraph individually
        // bracketed by headings), and isn't dominated by headings overall.
        //
        // Fix round 1 (Important #3): a run is broken by an intervening HEADING, not by an
        // intervening IMAGE. A photo essay (prose interleaved with inline photos, no heading
        // between paragraphs) has zero *adjacent* paragraph pairs under a naive "consecutive
        // block" reading even though it's obviously real prose -- `hasConsecutiveParagraphRun`
        // below now skips `.image` blocks entirely (neither extends nor breaks a run) so only
        // headings can interrupt one. See `testPasses_paragraphImageParagraph...` for the guard.
        guard hasConsecutiveParagraphRun(article.bodyBlocks, minimumRunLength: 2) else {
            return .fail(reason: "no run of 2+ consecutive paragraph blocks -- looks like furniture, not prose")
        }

        // Fix round 1 (Important #1/#2): the shipped 20% floor was defanged -- at 20%, the
        // ORIGINAL reported "quantum crossroads" body (reconstructed from
        // reader-extraction-investigation.md §1/§2's exact 22-block dump: 5 paragraphs / 10
        // headings = 33.3%) clears the ratio rule too, so fix D contributed nothing against the
        // exact shape it was added for -- the article was only actually rejected by the
        // pre-existing paragraphs.count >= 3 floor once fixes A+B trimmed the residual down to
        // 2 paragraphs. Per the investigation memo's §6(c) construction: the ratio floor now
        // only *engages* when the body has >= 3 heading blocks (an absolute floor, so a single
        // legitimate subhead never trips it -- see `testPasses_shortArticleWithSubheadAndTwoParagraphRuns`
        // and the memo's own Reason.com negative case), and the threshold itself is 40%, chosen
        // from three real measured bodies (device 9C2BEABB-B857-46FC-ACC4-F3884D9D6E07's live
        // stored articles, 2026-07-28):
        //   - the reported Reader article (reconstructed): 5P / 10H = 33.3% -- headings >= 3, so
        //     the rule engages, and 33.3% < 40% -- FAILS, as required.
        //   - abc7.com "find-great-deals-beauty-essentials-abc-secret-savings" (real, live,
        //     currently stored): 8P / 10H of 18 non-image blocks = 44.4% -- PASSES with a 4.4pt
        //     margin.
        //   - nbcnews.com/select "best-flats-with-arch-support" (real, live, currently stored):
        //     15P / 16H of 31 non-image blocks = 48.4% -- PASSES with an 8.4pt margin.
        // 40% sits with real margin on both sides: 6.7pts above the furniture shape it must
        // reject, 4.4-8.4pts below the two real listicles it must not reject.
        let headings = article.bodyBlocks.filter { $0.kind == .heading }
        if headings.count >= 3 {
            let nonImageBlockCount = paragraphs.count + headings.count
            // nonImageBlockCount can't be 0 here -- headings.count >= 3 makes it >= 3+3.
            let paragraphRatio = Double(paragraphs.count) / Double(nonImageBlockCount)
            guard paragraphRatio >= 0.4 else {
                let percent = Int((paragraphRatio * 100).rounded())
                return .fail(reason: "paragraphs are only \(percent)% of non-image blocks (with >= 3 headings), need >= 40%")
            }
        }

        let lowered = combinedText.lowercased()
        for marker in paywallMarkers {
            if lowered.contains(marker) {
                return .fail(reason: "paywall marker detected: \(marker)")
            }
        }

        // v1.12: language filter -- an ADDITIONAL gate layered on top of every rule above, same
        // "reject-rather-than-ship-something-wrong" placement `requiresAttribution` already
        // established at the top of this function. Checked last (not first) because it's the
        // most expensive rule in this file (the general fallback runs on-device ML inference) --
        // every cheaper structural/shape rule above gets a chance to reject first, so
        // LanguageFilter only ever runs against a body that's already cleared every floor.
        if englishOnly, let reason = LanguageFilter.nonEnglishRejectionReason(
            title: article.title, bodyBlocks: article.bodyBlocks, url: article.url
        ) {
            return .fail(reason: reason)
        }

        return .pass
    }

    /// True if `blocks` contains at least one run of `minimumRunLength`-or-more `.paragraph`
    /// blocks with no `.heading` interrupting it. `.image` blocks are neutral -- they neither
    /// extend nor break a run -- so a photo essay (prose interleaved with inline photos, no
    /// heading between paragraphs) still counts as one continuous passage of prose. Only a
    /// `.heading` marks a real section break; that's the actual "furniture vs. prose" signal
    /// (see the fix-D comment above the call site).
    private static func hasConsecutiveParagraphRun(_ blocks: [BodyBlock], minimumRunLength: Int) -> Bool {
        var currentRun = 0
        for block in blocks {
            switch block.kind {
            case .paragraph:
                currentRun += 1
                if currentRun >= minimumRunLength { return true }
            case .image:
                continue
            case .heading:
                currentRun = 0
            }
        }
        return false
    }
}
