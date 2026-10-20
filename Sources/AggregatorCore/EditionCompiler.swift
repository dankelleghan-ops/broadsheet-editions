import Foundation

// MARK: - Configuration

struct CompilerConfiguration {
    /// Public base URL the edition will be served from -- image URLs are absolute into
    /// `<base>/images/`. Trailing slash is normalized away.
    var baseURL: String
    var outDirectory: URL
    var stateFileURL: URL
    var windowHours: Int = 48
    /// Mirrors the app's `RefreshCoordinator.maxConcurrentSourceSurveys` (6): at most 6
    /// sources' feeds in flight at once, feeds sequential within a source.
    var surveyConcurrency: Int = 6
    /// Mirrors `RefreshCoordinator.maxConcurrentSourceDownloads` (3): at most 3 sources
    /// downloading article pages at once, pages sequential within a source. Hero images
    /// download inline in the same per-source loop, so image fetches are bounded by the same
    /// 3 -- inside the app's own 3-per-article x 3-source envelope.
    var downloadConcurrency: Int = 3
    /// Wall-clock budget for one run (finding 3b): once spent, no NEW source starts --
    /// in-flight sources finish, the edition and state still write with what the run has, and
    /// the process exits 0 with a budget-truncated note in the run log. 20 minutes keeps the
    /// compiler comfortably inside the workflow's 25-minute kill, so a slow run degrades to a
    /// partial edition instead of a total loss. Skipped sources' feed conditionals are never
    /// committed, so the next run picks their items up in full.
    var runBudgetSeconds: TimeInterval = 20 * 60
    /// Per-source eligible-item cap for one run (finding 3c) -- a pathological feed dump
    /// cannot monopolize the run. A capped source's feed conditionals are deliberately NOT
    /// committed, so the next run re-fetches the feed and drains the remainder
    /// (already-compiled GUIDs skip as known). 60 is ~1.5x the largest per-day cap in the
    /// catalog -- far above any legitimate half-hourly delta.
    var maxItemsPerSourcePerRun: Int = 60
    var now: () -> Date = Date.init

    var windowSeconds: TimeInterval { TimeInterval(windowHours) * 3600 }
    var normalizedBaseURL: String {
        baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }
}

// MARK: - Stats

struct SourceRunStats {
    let sourceID: String
    var feedsFetched = 0
    var feedsNotModified = 0
    var feedErrors = 0
    var eligibleItems = 0
    var skippedPreviouslyRejected = 0
    var newArticles = 0
    var gateRejected = 0
    var failures = 0
    var imagesWritten = 0
    var imageFailures = 0
    /// Feed-text articles whose hero was swapped for a wider rendition found on the article page
    /// (see `EditionCompiler.pageHeroUpgradeSourceIDs`).
    var heroUpgrades = 0
    /// New articles whose date came from the article PAGE because the feed item carried none.
    var datesFromPage = 0
    /// New articles with NO real date anywhere (no usable feed date, none on the page): stamped with the
    /// compile time and marked `dateIsEstimated` in the edition. Should be 0 for a healthy source.
    var datesEstimated = 0
    /// Already-compiled articles whose guessed/stale date was replaced by the real one the feed now carries.
    var datesCorrected = 0
    /// Undated feed items whose PAGE date showed they are older than the edition window: not compiled
    /// (and negative-cached, so the page is not fetched again every run).
    var staleByPageDate = 0
    /// Finding 3c: true when the per-run eligible-item cap cut this source's survey short.
    var hitItemCap = false
    /// Sections: how many of this source's TOPIC feeds hit their own per-run cap (`FeedEndpoint.topicMaxPerDay`) this run. Each
    /// such feed's remainder drains on later runs (its feed conditional is not committed).
    var topicFeedsCapped = 0
    /// Sections: new articles compiled through this source's topic feeds this run (a subset of `newArticles`).
    var topicNewArticles = 0
}

struct RunStats {
    var perSource: [SourceRunStats] = []
    var totalArticles = 0
    var newArticles = 0
    var retainedArticles = 0
    var gzippedBytes = 0
    var imageCount = 0
    var imageBytes: Int64 = 0
    var prunedImageCount = 0
    var wallClockSeconds: Double = 0
    /// Finding 3b: true when the run budget expired before every source was processed.
    var budgetTruncated = false
    /// Sources whose compile work was deferred to the next run (each source counts at most
    /// once: either its survey never started, or it surveyed but its download never started).
    var skippedSourceCount = 0
}

// MARK: - Compiler

/// The end-to-end edition compile: survey feeds (conditional GETs) -> extract/gate new items
/// (the EXACT vendored app pipeline) -> hero image download+resize -> merge with retained
/// articles -> emit edition.json.gz + images/ -> prune -> save state.
final class EditionCompiler {
    private let catalog: [SourceConfig]
    private let client: AggregatorHTTPClient
    private let resizer: ImageResizing
    private let config: CompilerConfiguration
    private let feedParser = FeedParser()
    private let extractor = ContentExtractor()

    init(catalog: [SourceConfig], client: AggregatorHTTPClient, resizer: ImageResizing,
         configuration: CompilerConfiguration) {
        self.catalog = catalog
        self.client = client
        self.resizer = resizer
        self.config = configuration
    }

    func run() async throws -> RunStats {
        let started = Date()
        let now = config.now()
        // Finding 3b: the budget gates NEW source starts in both phases below; in-flight
        // sources always finish, and everything completed still ships.
        let budgetDeadline = now.addingTimeInterval(config.runBudgetSeconds)
        let withinBudget: () -> Bool = { self.config.now() < budgetDeadline }
        var state = CompilerState.load(from: config.stateFileURL)
        state.prune(now: now, windowSeconds: config.windowSeconds)

        let imagesDir = config.outDirectory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        // Phase A: survey every source's feeds (conditional GETs), collect eligible new items.
        // NOTE (finding 3a): updated feed conditionals are NOT committed to state here -- each
        // source's conditionals commit together with that source's downloaded articles in
        // Phase B. A checkpoint carrying a fresher conditional than the articles it actually
        // compiled would make the next run 304 straight past the items a killed run lost.
        let knownGUIDs = Set(state.articles.map(\.guid))
        let retainedDates = Dictionary(state.articles.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
        let rejected = Set(state.rejectedURLs.keys)
        let conditionals = state.feedConditionals
        var surveys: [SourceSurveyResult] = []
        let surveysSkipped = await boundedConcurrentForEach(catalog, limit: config.surveyConcurrency,
                                                            shouldStartMore: withinBudget,
                                                            transform: { source in
            await self.survey(source: source, knownGUIDs: knownGUIDs, retainedDates: retainedDates,
                              rejectedURLStrings: rejected, conditionals: conditionals, now: now)
        }, onResult: { surveys.append($0) })

        // Phase B: download/extract/gate the new items; write hero images. State checkpoints
        // after EVERY completed source (finding 3a): a killed run resumes from the last
        // completed source instead of restarting from nothing.
        var stats = RunStats()
        let retainedAtStart = state.articles
        var newArticles: [CompiledArticle] = []
        var dateCorrections: [String: Date] = [:]
        let downloadsSkipped = await boundedConcurrentForEach(surveys, limit: config.downloadConcurrency,
                                                              shouldStartMore: withinBudget,
                                                              transform: { survey in
            await self.download(survey: survey, imagesDir: imagesDir, now: now)
        }, onResult: { download in
            stats.perSource.append(download.stats)
            newArticles.append(contentsOf: download.articles)
            dateCorrections.merge(download.dateCorrections) { first, _ in first }
            for url in download.rejectedURLs {
                state.recordRejection(url, now: now)
            }
            for (feedURL, conditional) in download.updatedConditionals {
                state.feedConditionals[feedURL] = conditional
            }
            state.articles = retainedAtStart + newArticles
            // Best-effort: a transient checkpoint-write failure must not sink the run (the
            // final save below still throws).
            try? state.save(to: self.config.stateFileURL)
        })
        stats.skippedSourceCount = surveysSkipped + downloadsSkipped
        stats.budgetTruncated = stats.skippedSourceCount > 0

        // Phase C: merge, restore any retained image the output-dir cache lost, emit, prune.
        var retained = retainedAtStart
        // Date corrections for already-compiled articles (see `survey`). The guid -- the state key and the
        // phone's dedupe key -- never changes, so a correction can neither duplicate an article nor make
        // it look new; only `publishedAt`/`dateIsEstimated` move. An article whose REAL date puts it
        // outside the window leaves the edition here, exactly as it would have had it been dated
        // correctly in the first place; it is not re-added later (the survey applies the same cutoff).
        if !dateCorrections.isEmpty {
            for index in retained.indices {
                guard let real = dateCorrections[retained[index].guid] else { continue }
                retained[index].publishedAt = real
                retained[index].dateIsEstimated = false
                if let statsIndex = stats.perSource.firstIndex(where: { $0.sourceID == retained[index].sourceID }) {
                    stats.perSource[statsIndex].datesCorrected += 1
                }
            }
            let cutoff = now.addingTimeInterval(-config.windowSeconds)
            retained.removeAll { $0.publishedAt < cutoff }
        }
        await restoreMissingImages(for: &retained, imagesDir: imagesDir)
        let merged = retained + newArticles
        state.articles = merged

        let edition = buildEdition(from: merged, generatedAt: now)
        let editionData = try edition.encodedJSON()
        let editionURL = config.outDirectory.appendingPathComponent("edition.json.gz")
        try GzipWriter.writeGzipped(editionData, to: editionURL)

        let referenced = Set(merged.compactMap(\.imageSHA16))
        stats.prunedImageCount = pruneImages(in: imagesDir, keeping: referenced)

        try state.save(to: config.stateFileURL)

        stats.totalArticles = merged.count
        stats.newArticles = newArticles.count
        stats.retainedArticles = retained.count
        stats.gzippedBytes = (try? Data(contentsOf: editionURL).count) ?? 0
        let (imageCount, imageBytes) = imageDirStats(imagesDir)
        stats.imageCount = imageCount
        stats.imageBytes = imageBytes
        stats.wallClockSeconds = Date().timeIntervalSince(started)
        return stats
    }

    // MARK: - Phase A: survey

    struct SourceSurveyResult {
        let source: SourceConfig
        var eligibleItems: [FeedItem] = []
        var updatedConditionals: [String: FeedConditional] = [:]
        /// guid -> the real publish time the feed now carries for an ALREADY-COMPILED article whose
        /// stored date is a guess (see `survey`); applied in Phase C.
        var dateCorrections: [String: Date] = [:]
        /// Sections: guid -> the topic hint of the topic feed that supplied the item. Absent for an item taken through a main-news
        /// feed.
        var topicHints: [String: String] = [:]
        /// Sections: the keys (URL strings) of topic feeds that hit their per-run cap this run. Their feed conditionals are NOT
        /// committed (same reasoning as finding 3c), so the next run re-fetches the feed and drains the remainder.
        var cappedFeedKeys: Set<String> = []
        var stats: SourceRunStats
    }

    /// Mirrors the pre-filters of the app's `ArticleStore.surveyFeeds`: guid-as-URL preference,
    /// exclude patterns/prefixes, in-run guid dedupe, already-stored guid skip, rejected-URL
    /// skip -- plus the edition's own window cutoff (`publishedAt ?? now` within the last 48h,
    /// the same nil-coercion the app applies at store time).
    ///
    /// Sections: a feed that declares a topic (`FeedEndpoint.topicHint`) is a TOPIC FEED. Its items are tagged with that hint (it
    /// travels into the bundle as `topicHint`) and are capped PER FEED at `FeedEndpoint.topicMaxPerDay` new items per run. They do
    /// not count against `maxItemsPerSourcePerRun`, which now limits a source's MAIN feeds only, so a busy topic feed can never
    /// crowd out a source's main-news feeds and a busy main feed can never starve a topic feed (a source's main feeds are listed
    /// first and the main cap used to end the whole survey). The web-address and sports-headline rules of `ArticleGate` also run
    /// here, before any page is fetched; the gate repeats them for what slips through.
    private func survey(source: SourceConfig, knownGUIDs: Set<String>, retainedDates: [String: CompiledArticle],
                        rejectedURLStrings: Set<String>,
                        conditionals: [String: FeedConditional], now: Date) async -> SourceSurveyResult {
        var result = SourceSurveyResult(source: source, stats: SourceRunStats(sourceID: source.id))
        var processedGUIDs = Set<String>()
        let cutoff = now.addingTimeInterval(-config.windowSeconds)
        /// Eligible items taken through MAIN feeds: the only ones `maxItemsPerSourcePerRun` counts.
        var mainEligibleCount = 0

        for feed in source.feeds {
            let feedKey = feed.url.absoluteString
            let topicHint = feed.normalizedTopicHint
            // Main cap reached (finding 3c): the source's remaining MAIN feeds are skipped, exactly as before. Topic feeds
            // still run: they have their own caps.
            if result.stats.hitItemCap && topicHint == nil { continue }
            var feedEligibleCount = 0
            do {
                let response = try await client.get(feed.url, conditional: conditionals[feedKey],
                                                    maxBytes: FetchLimits.pageBytes)
                if response.isNotModified {
                    result.stats.feedsNotModified += 1
                    continue
                }
                result.stats.feedsFetched += 1
                if response.etag != nil || response.lastModified != nil {
                    result.updatedConditionals[feedKey] = FeedConditional(etag: response.etag,
                                                                          lastModified: response.lastModified)
                }
                let parsed = try feedParser.parse(data: response.data, endpoint: feed)
                let items = FeedParser.applyGUIDAsURLPreference(to: parsed, enabled: source.preferGUIDAsURL)
                for item in items {
                    if source.excludeURLPatterns.contains(where: { item.url.path.contains($0) }) { continue }
                    if source.excludeTitlePrefixes.contains(where: { item.title.lowercased().hasPrefix($0.lowercased()) }) { continue }
                    if processedGUIDs.contains(item.guid) { continue }
                    if knownGUIDs.contains(item.guid) {
                        // Already compiled -- never re-fetched. But if its stored date is a guess (or
                        // unknown: compiled before `dateIsEstimated` existed) and the feed now carries a
                        // real date that is EARLIER by more than a minute, remember the correction. Only an
                        // earlier date qualifies: a first-seen stamp is always later than the real publish
                        // time, whereas a feed that merely bumps its pubDate on an update moves it later.
                        if let real = item.publishedAt, let stored = retainedDates[item.guid],
                           stored.dateIsEstimated != false, real < stored.publishedAt.addingTimeInterval(-60) {
                            result.dateCorrections[item.guid] = real
                        }
                        continue
                    }
                    if rejectedURLStrings.contains(item.url.absoluteString) {
                        result.stats.skippedPreviouslyRejected += 1
                        continue
                    }
                    if (item.publishedAt ?? now) < cutoff { continue }
                    // Sections: pages the gate would reject by their web address or (sports feeds) headline are skipped before
                    // any fetch. Not negative-cached: the check is free, so it is simply repeated.
                    if ArticleGate.addressRejectionReason(item.url) != nil { continue }
                    if topicHint == ArticleGate.sportsTopicHint,
                       ArticleGate.sportsFeedTitleRejectionReason(item.title) != nil { continue }
                    if let topicHint {
                        // Sections: a topic feed takes at most `topicMaxPerDay` new items per run, newest first (feed order).
                        if feedEligibleCount >= feed.topicMaxPerDay {
                            result.cappedFeedKeys.insert(feedKey)
                            result.stats.topicFeedsCapped += 1
                            break
                        }
                        processedGUIDs.insert(item.guid)
                        result.eligibleItems.append(item)
                        result.topicHints[item.guid] = topicHint
                        feedEligibleCount += 1
                    } else {
                        if mainEligibleCount >= config.maxItemsPerSourcePerRun {
                            // Finding 3c: cap reached with more eligible items still in the feed.
                            // Marking the cap keeps this source's conditionals uncommitted (see
                            // `download`), so the next run drains the remainder.
                            result.stats.hitItemCap = true
                            break
                        }
                        processedGUIDs.insert(item.guid)
                        result.eligibleItems.append(item)
                        mainEligibleCount += 1
                    }
                }
            } catch {
                result.stats.feedErrors += 1
                DiagnosticsLog.shared.log(.error, source: source.id,
                                          "feed fetch/parse failed for \(feedKey): \(error)")
            }
        }
        result.stats.eligibleItems = result.eligibleItems.count
        return result
    }

    // MARK: - Phase B: download + extract + gate + image

    struct SourceDownloadResult {
        var articles: [CompiledArticle] = []
        var rejectedURLs: [URL] = []
        /// The survey's updated feed conditionals, committed to state together with this
        /// source's articles (finding 3a -- see run()'s Phase A note).
        var updatedConditionals: [String: FeedConditional] = [:]
        /// Carried over from the survey (see `SourceSurveyResult.dateCorrections`).
        var dateCorrections: [String: Date] = [:]
        var stats: SourceRunStats
    }

    /// Feed-text sources whose feed carries only a small lead photo while the article page publishes a
    /// much wider rendition of the SAME photo (measured 2026-10-11): Sun-Times and WBEZ 840 px -> 1486,
    /// ProPublica 1149 -> 1536, Block Club 1024 -> 1536. Everything else stays exactly as it was: the
    /// other feed-text sources' pages offer no larger rendition of their feed photo, and page-extract
    /// sources already take the page's own image. See `ContentExtractor.upgradingHero`.
    static let pageHeroUpgradeSourceIDs: Set<String> = ["suntimes", "wbez", "propublica", "blockclub"]

    private func download(survey: SourceSurveyResult, imagesDir: URL, now: Date) async -> SourceDownloadResult {
        // Finding 3c: a capped source commits NO conditionals -- committing one would 304 the
        // next run straight past the eligible items this run left behind. Sections: a capped TOPIC feed (own per-run cap)
        // withholds just its own conditional, so the next run re-fetches that feed and drains its remainder while its
        // siblings stay cheap.
        var result = SourceDownloadResult(updatedConditionals: survey.stats.hitItemCap
                                              ? [:]
                                              : survey.updatedConditionals.filter { !survey.cappedFeedKeys.contains($0.key) },
                                          dateCorrections: survey.dateCorrections,
                                          stats: survey.stats)
        let source = survey.source

        for item in survey.eligibleItems {
            var extracted: ExtractedArticle
            do {
                switch source.strategy {
                case .feedFullText:
                    guard let html = item.contentHTML else {
                        // Mirrors the app's v1.13.1 hygiene: a feed item with no
                        // content:encoded is a deterministic content-shape failure --
                        // negative-cache it like a gate rejection.
                        result.stats.failures += 1
                        result.rejectedURLs.append(item.url)
                        DiagnosticsLog.shared.log(.warn, source: source.id,
                                                  "missing full-text content for \(item.guid)")
                        continue
                    }
                    extracted = try extractor.extract(fromFeedHTML: html, item: item)
                case .pageExtract:
                    let page = try await client.get(item.url, maxBytes: FetchLimits.pageBytes)
                    let pageHTML = String(decoding: page.data, as: UTF8.self)
                    extracted = try extractor.extract(fromPageHTML: pageHTML, articleURL: item.url,
                                                      item: item, config: source)
                }
            } catch {
                result.stats.failures += 1
                if case FetchError.responseTooLarge(let limit) = error {
                    // Finding 3e: oversize is deterministic for as long as the page stays
                    // oversize -- negative-cache it like a gate rejection so half-hourly runs
                    // don't re-pull (and re-abort) megabytes for the same URL for 7 days.
                    result.rejectedURLs.append(item.url)
                    DiagnosticsLog.shared.log(.warn, source: source.id,
                                              "page exceeded \(limit)-byte cap for \(item.guid)")
                } else {
                    // Genuine network/extraction failure -- retryable, never negative-cached
                    // (same split the app keeps).
                    DiagnosticsLog.shared.log(.warn, source: source.id,
                                              "extraction failed for \(item.guid): \(error)")
                }
                continue
            }

            let topicHint = survey.topicHints[item.guid]
            let gateResult = ArticleGate.evaluate(extracted, requiresAttribution: source.requiresAttribution,
                                                  englishOnly: true, sourceID: source.id, topicHint: topicHint,
                                                  // The 7-day age rule is for topic feeds (evergreen archives such as the
                                                  // Guardian's travel guides), as on the phone; the survey's window cutoff
                                                  // already bounds every other item.
                                                  publishedAt: topicHint == nil ? nil : item.publishedAt, now: now)
            guard case .pass = gateResult else {
                result.stats.gateRejected += 1
                if case .fail(let reason) = gateResult {
                    DiagnosticsLog.shared.log(.warn, source: source.id,
                                              "gate failed for \(item.guid): \(reason)")
                }
                result.rejectedURLs.append(item.url)
                continue
            }

            // Feed-text sources whose FEED carries only a small rendition of the lead photo: look the same
            // photo up on the article page and take the wider rendition the page publishes. Only for
            // articles that already passed the gate (no page is fetched for a rejected one), pages one at
            // a time inside the source's own loop (same politeness as page-extract sources), and any
            // failure keeps the feed's hero -- never fails the article.
            //
            // The same fetch also serves the DATE: a feed-text item whose feed carries no usable date
            // takes the page's own `datePublished` (below), so a source needing both costs ONE request;
            // a feed-text source that needs only the date (rare: an undated feed item) costs one.
            let wantsHeroUpgrade = source.strategy == .feedFullText
                && Self.pageHeroUpgradeSourceIDs.contains(source.id) && extracted.heroImageURL != nil
            let wantsPageDate = source.strategy == .feedFullText && item.publishedAt == nil
            var pagePublishedAt = extracted.publishedAt   // page-extract sources: read by the extractor already
            if wantsHeroUpgrade || wantsPageDate {
                do {
                    let page = try await client.get(item.url, maxBytes: FetchLimits.pageBytes)
                    let pageHTML = String(decoding: page.data, as: UTF8.self)
                    if wantsHeroUpgrade,
                       let upgraded = ContentExtractor.upgradingHero(of: extracted, fromPageHTML: pageHTML,
                                                                    pageURL: item.url) {
                        extracted = upgraded
                        result.stats.heroUpgrades += 1
                    }
                    if wantsPageDate { pagePublishedAt = ContentExtractor.pagePublishedAt(inPageHTML: pageHTML) }
                } catch {
                    DiagnosticsLog.shared.log(.warn, source: source.id,
                                              "page fetch failed for \(item.guid) (hero upgrade / date lookup skipped): \(error)")
                }
            }

            // The article's date: the feed item's own, else the page's ORIGINAL publish time, and only
            // when neither exists the compile time -- flagged `dateIsEstimated` so downstream code can tell
            // it is a guess (and counted per source in the run report).
            let publishedAt: Date
            let dateIsEstimated: Bool
            if let feedDate = item.publishedAt {
                (publishedAt, dateIsEstimated) = (feedDate, false)
            } else if let pageDate = pagePublishedAt {
                (publishedAt, dateIsEstimated) = (pageDate, false)
                result.stats.datesFromPage += 1
                if pageDate < now.addingTimeInterval(-config.windowSeconds) {
                    // The page shows this undated feed item is older than the window: it never belonged
                    // in the edition. Negative-cache it so its page is not fetched again every run.
                    result.stats.staleByPageDate += 1
                    result.rejectedURLs.append(item.url)
                    continue
                }
            } else {
                (publishedAt, dateIsEstimated) = (now, true)
                result.stats.datesEstimated += 1
                DiagnosticsLog.shared.log(.warn, source: source.id,
                                          "no real publish date for \(item.guid) -- stamped with the compile time")
            }

            let bodyBlocksJSON: String
            do {
                bodyBlocksJSON = try BodyBlockJSON.encode(extracted.bodyBlocks)
            } catch {
                result.stats.failures += 1
                continue
            }

            // Hero image: best-effort. Unlike the app (which rejects an article whose image
            // downloads fail -- it promises offline completeness), the edition ships the
            // article text-first with `topImageURL: nil`; the contract makes the image
            // optional and the phone tolerates its absence.
            var imageSHA16: String?
            if let heroURL = extracted.heroImageURL {
                do {
                    imageSHA16 = try await downloadAndWriteImage(from: heroURL, imagesDir: imagesDir)
                    result.stats.imagesWritten += 1
                } catch {
                    result.stats.imageFailures += 1
                    DiagnosticsLog.shared.log(.warn, source: source.id,
                                              "hero image failed for \(item.guid): \(error)")
                }
            }

            let attribution = source.requiresAttribution
                ? AttributionText.creditLine(author: extracted.author, institution: extracted.authorInstitution)
                : nil

            result.articles.append(CompiledArticle(
                guid: item.guid,
                url: item.url.absoluteString,
                sourceID: source.id,
                title: extracted.title,
                author: extracted.author,
                attribution: attribution,
                publishedAt: publishedAt,
                dateIsEstimated: dateIsEstimated,
                bodyBlocksJSON: bodyBlocksJSON,
                imageSHA16: imageSHA16,
                imageSourceURL: extracted.heroImageURL?.absoluteString,
                topicHint: topicHint
            ))
            result.stats.newArticles += 1
            if topicHint != nil { result.stats.topicNewArticles += 1 }
        }
        return result
    }

    /// Downloads a hero image, resizes it per the contract (longest edge 1400, JPEG q0.72,
    /// opaque), and files it under its content sha: `images/<sha256-16>.jpg`. Returns the
    /// sha16. Two articles sharing one image converge on the same file.
    private func downloadAndWriteImage(from url: URL, imagesDir: URL) async throws -> String {
        let response = try await client.get(url, maxBytes: FetchLimits.imageBytes)
        let resizedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broadsheet-resized-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: resizedURL) }
        try resizer.resize(rawData: response.data, outputURL: resizedURL)
        let resizedData = try Data(contentsOf: resizedURL)
        let sha16 = SHA256.hexDigest16(resizedData)
        let finalURL = imagesDir.appendingPathComponent("\(sha16).jpg")
        if !FileManager.default.fileExists(atPath: finalURL.path) {
            do {
                try FileManager.default.moveItem(at: resizedURL, to: finalURL)
            } catch {
                // A concurrent task may have landed the identical content-addressed file
                // between the exists-check and the move -- only rethrow if it's still absent.
                if !FileManager.default.fileExists(atPath: finalURL.path) { throw error }
            }
        }
        return sha16
    }

    // MARK: - Phase C helpers

    /// A run that lost the output-directory cache still has every retained article's
    /// `imageSourceURL` -- re-download and re-resize sequentially (rare path; zero cost when
    /// the cache held).
    private func restoreMissingImages(for articles: inout [CompiledArticle], imagesDir: URL) async {
        for index in articles.indices {
            guard let sha = articles[index].imageSHA16 else { continue }
            let fileURL = imagesDir.appendingPathComponent("\(sha).jpg")
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            guard let sourceURLString = articles[index].imageSourceURL,
                  let sourceURL = URL(string: sourceURLString) else {
                articles[index].imageSHA16 = nil
                continue
            }
            do {
                articles[index].imageSHA16 = try await downloadAndWriteImage(from: sourceURL, imagesDir: imagesDir)
            } catch {
                articles[index].imageSHA16 = nil
                DiagnosticsLog.shared.log(.warn, source: articles[index].sourceID,
                                          "retained image restore failed for \(sourceURL): \(error)")
            }
        }
    }

    func buildEdition(from articles: [CompiledArticle], generatedAt: Date) -> Edition {
        let sorted = articles.sorted {
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
            return $0.guid < $1.guid
        }
        let base = config.normalizedBaseURL
        return Edition(
            schemaVersion: 1,
            generatedAt: EditionDates.string(from: generatedAt),
            windowHours: config.windowHours,
            articles: sorted.map { article in
                EditionArticle(
                    guid: article.guid,
                    url: article.url,
                    sourceID: article.sourceID,
                    title: article.title,
                    author: article.author,
                    publishedAt: EditionDates.string(from: article.publishedAt),
                    bodyBlocksJSON: article.bodyBlocksJSON,
                    topImageURL: article.imageSHA16.map { "\(base)/images/\($0).jpg" },
                    attribution: article.attribution,
                    // Only a GUESSED date is flagged; a real (or legacy/unknown) one omits the key.
                    dateIsEstimated: article.dateIsEstimated == true ? true : nil,
                    // Sections: the topic feed it came through; omitted (nil) for a main-news article.
                    topicHint: article.topicHint
                )
            }
        )
    }

    /// Removes any `images/*.jpg` no longer referenced by a windowed article. Because every
    /// article is itself windowed at 48h, this IS the "images older than 48h are dropped"
    /// output-pruning rule -- reference-based, so an image shared by a newer article survives.
    func pruneImages(in imagesDir: URL, keeping referencedSHA16s: Set<String>) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: imagesDir,
                                                                         includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for entry in entries where entry.pathExtension == "jpg" {
            let sha = entry.deletingPathExtension().lastPathComponent
            if !referencedSHA16s.contains(sha) {
                try? FileManager.default.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }

    private func imageDirStats(_ imagesDir: URL) -> (count: Int, bytes: Int64) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: imagesDir,
                                                                         includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for entry in entries where entry.pathExtension == "jpg" {
            count += 1
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += Int64(size)
        }
        return (count, bytes)
    }
}

// MARK: - Bounded concurrency

/// Streaming sibling of `boundedConcurrentMap` (findings 3a/3b): `onResult` runs serially, in
/// completion order, as each transform finishes -- the per-source checkpoint hook -- and
/// `shouldStartMore` is consulted before every task start -- the run-budget hook (in-flight
/// transforms always finish; only NEW starts stop). Returns how many inputs were never
/// started.
@discardableResult
func boundedConcurrentForEach<T, R>(_ inputs: [T], limit: Int,
                                    shouldStartMore: () -> Bool = { true },
                                    transform: @escaping (T) async -> R,
                                    onResult: (R) async -> Void) async -> Int {
    guard !inputs.isEmpty else { return 0 }
    var started = 0
    await withTaskGroup(of: R.self) { group in
        func startNext() -> Bool {
            guard started < inputs.count, shouldStartMore() else { return false }
            let input = inputs[started]
            started += 1
            group.addTask { await transform(input) }
            return true
        }
        while started < min(limit, inputs.count) {
            if !startNext() { break }
        }
        for await result in group {
            await onResult(result)
            _ = startNext()
        }
    }
    return inputs.count - started
}

/// Order-preserving concurrent map with at most `limit` transforms in flight -- the same
/// "start `limit`, top up as each finishes" pattern the app's RefreshCoordinator uses.
func boundedConcurrentMap<T, R>(_ inputs: [T], limit: Int,
                                _ transform: @escaping (T) async -> R) async -> [R] {
    guard !inputs.isEmpty else { return [] }
    var results = [R?](repeating: nil, count: inputs.count)
    await withTaskGroup(of: (Int, R).self) { group in
        var nextIndex = 0
        func addTask() {
            let index = nextIndex
            let input = inputs[index]
            nextIndex += 1
            group.addTask { (index, await transform(input)) }
        }
        while nextIndex < min(limit, inputs.count) { addTask() }
        for await (index, value) in group {
            results[index] = value
            if nextIndex < inputs.count { addTask() }
        }
    }
    return results.map { $0! }
}
