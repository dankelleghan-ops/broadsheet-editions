# BroadsheetAggregator

The server half of Broadsheet's edition pipeline: a standalone SwiftPM package whose
`compile-edition` executable fetches every catalog feed, extracts and gates articles with the
**exact same code the iOS app runs**, downloads and resizes hero images, and writes a single
downloadable "edition" bundle. Phones then download ONE bundle instead of each hitting 25
news sites — the next big lever for refresh smoothness and battery.

This phase is **local-only**: the package, its tests, and the workflow file live in this repo,
but nothing is published anywhere yet. A later publish phase creates the public GitHub repo,
moves `github-workflow-edition.yml` into its `.github/workflows/`, and turns on Pages.

## Edition format contract v1

Both halves (this compiler; the app's future edition-ingest path) build against THIS. Neither
may change it unilaterally.

- Published at `<base>/edition.json.gz` (gzip JSON) and `<base>/images/<sha256-16>.jpg`.
  `<base>` is configurable (`--base-url`); production will be a GitHub Pages URL.
- `edition.json`:
  `{ "schemaVersion": 1, "generatedAt": ISO8601-UTC, "windowHours": 48, "articles": [ ... ] }`
- article:
  ```
  {
    "guid":           String   // the app's existing guid convention per source
    "url":            String
    "sourceID":       String   // must match SourceCatalog IDs
    "title":          String
    "author":         String?
    "publishedAt":    ISO8601
    "bodyBlocksJSON": String   // EXACTLY the app's persisted BodyBlock array JSON --
                               // the same JSONEncoder().encode([BodyBlock]) shape
                               // ArticleStore writes (nil fields omitted; note default
                               // JSONEncoder does not pin KEY ORDER, so "same shape"
                               // means what JSONDecoder consumes, not byte order)
    "topImageURL":    String?  // absolute URL into <base>/images/
    "attribution":    String?  // the v1.8 Conversation credit line when applicable
  }
  ```
- Server-side responsibilities: feed parse, full-text extraction, ArticleGate pass/fail,
  LanguageFilter, image download+resize (longest edge 1400px, JPEG q0.72, opaque) named by
  content sha. Phone-side (all EXISTING code paths, unchanged): categorization, subtopics,
  lean, ranking, editor scoring, per-day caps, dedup by guid.
- Articles: last 48h, all catalog sources, gate-passing only. Bundle stays under ~8MB gzipped
  (text only; images separate).

## Code sharing — the drift rule

`Sources/AggregatorCore/Vendored/` holds byte-for-byte copies of eight app sources
(SourceCatalog, FeedParser, ContentExtractor, ArticleGate, LanguageFilter, CoreTypes,
ArticleCategory, AttributionText). They are **generated, never edited**:

- `./sync-shared-sources.sh` copies the originals from `Broadsheet/` and stamps
  `Vendored/MANIFEST.sha256`.
- `./sync-shared-sources.sh --check` (and `VendoredSourceDriftTests`, on every `swift test`)
  fails loudly if any original has drifted from its copy. Drift is detectable, never silent.
- Portability lives in the ORIGINALS (`#if canImport(FoundationXML)` for XMLParser on Linux,
  `#if canImport(NaturalLanguage)` compiling out the ML language fallback), so copies stay
  exact and the app suite stays green. If a shared file ever needs more than trivial `#if`
  surgery, refactor the original — do not fork the copy.
- App-only symbols the vendored files reference (`Prefs`, `DiagnosticsLog`) are satisfied by
  minimal shims in `Shims.swift` — symbols only, never alternative pipeline logic.

On Linux the LanguageFilter's `NLLanguageRecognizer` fallback is compiled out; the structural
la-voz rule still runs, and the phone re-applies its full filter on ingest (defense in depth,
no fidelity loss).

## Running it

```sh
cd aggregator
swift run -c release compile-edition \
  --out /tmp/broadsheet-edition \
  --base-url https://<user>.github.io/<repo> \
  --state /tmp/broadsheet-edition-state.json   # optional; defaults next to --out
```

- Requires an image tool: ImageMagick (`magick` or `convert`; preinstalled on GitHub's
  Ubuntu runners) or `sips` (any Mac). vips is deliberately not wired up — ImageMagick is
  guaranteed on the runners, and a third untested variant helps nobody.
- The state file carries feed ETag/Last-Modified conditionals, every windowed article
  (already compiled — never re-fetched), and a 7-day negative cache of gate-rejected URLs
  (mirroring the app's GateRejectionStore). Steady-state runs are therefore mostly 304s.
- Politeness: concurrency caps mirror the app's (6 concurrent source surveys, 3 concurrent
  source downloads with pages sequential per source, hero images inside that same 3-way
  envelope), 20s timeouts, and an honest User-Agent
  (`BroadsheetEditionCompiler/1.0 ...`) — this is an automated fetcher and says so.
- Output pruning: any `images/*.jpg` not referenced by a windowed article is deleted each
  run. Articles window out at 48h, so this IS the 48h image prune.
- Total-loss hardening (pre-publish review, finding 3): state checkpoints after EVERY
  completed source (a killed run resumes from the last completed source — a source's feed
  conditionals only ever commit together with its articles, so a kill can never strand
  items behind a 304); a 20-minute in-process wall-clock budget stops STARTING new sources
  (in-flight ones finish, the edition + state still write, exit 0 with a BUDGET-TRUNCATED
  note) so the workflow's 25-minute kill never produces a total loss; a per-source
  eligible-item cap (60/run — capped sources skip their conditional commit so the
  remainder drains next run) keeps a pathological feed dump from monopolizing a run; and
  response-size caps (pages/feeds 10MB, images 30MB) abort oversize downloads mid-flight,
  with oversize pages negative-cached like gate rejections.
- The run report prints per-source counts, bundle size (warning above the ~8MB target),
  image totals, and wall clock.

## Tests

```sh
cd aggregator && swift test   # 60 tests, no live network
```

Contract shape (golden round-trips, app-encoder-shape bodyBlocksJSON), vendored gate/language
parity spot-checks, extractor runs against the app suite's own fixtures
(`BroadsheetTests/Fixtures`), end-to-end compiles against a fake HTTP client (steady-state
304s, negative-cache skips, windowing, image-failure text-first tolerance), pruning, resize
command builders (including the sips no-upscale guard), SHA-256 NIST vectors, drift
detection, and the total-loss hardening (mid-run state checkpoints observed on disk, a
fake-clock budget truncation, item-cap drain across two runs, concurrent pipe drains past
the 64KB buffer, and size-cap decisions plus compiler-level cap behavior).

## How the Actions workflow will invoke it (publish phase)

`github-workflow-edition.yml` (in this directory — **not installed**; the publish phase moves
it to `.github/workflows/` in the public repo):

1. cron every 30 minutes (plus manual dispatch),
2. checkout + Swift setup on ubuntu,
3. `actions/cache` restores the state file and the output directory (so images and
   conditionals survive between runs; a cache miss just means one more expensive run —
   the compiler re-downloads retained articles' images from their recorded source URLs),
4. `swift run -c release compile-edition --out out --base-url <the Pages URL>`,
5. force-push `out/` to `gh-pages` as a single commit (history stays one commit deep;
   Pages serves `edition.json.gz` + `images/`).

Design notes the publish phase must keep: the state file lives OUTSIDE the output directory
(it must never be published); the gh-pages push is `--force` with a fresh orphan commit each
run; concurrency guard so overlapping crons never double-push.
