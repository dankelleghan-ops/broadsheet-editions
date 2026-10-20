# BroadsheetAggregator

The server half of Broadsheet's edition pipeline: a standalone SwiftPM package whose
`compile-edition` executable fetches every catalog feed, extracts and gates articles with the
**exact same code the iOS app runs**, downloads and resizes hero images, and writes a single
downloadable "edition" bundle. Phones then download ONE bundle instead of each hitting 25
news sites — the next big lever for refresh smoothness and battery.

This is **live**: the package, its tests, and the canonical workflow file live in this repo;
the compiler runs on GitHub Actions in the public repo
`dankelleghan-ops/broadsheet-editions` (which carries a copy of the package plus the workflow
at `.github/workflows/edition.yml` and a root copy, `github-workflow-edition.yml`), and
GitHub Pages serves the `gh-pages` branch at
`https://dankelleghan-ops.github.io/broadsheet-editions/`. Edit the workflow HERE, then copy
the same file to both places in the editions repo so the three stay identical.

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
    "dateIsEstimated": Bool?   // ADDITIVE (2026-10-12): true ONLY when no real publish time could be found and
                               // publishedAt is the compiler's first-seen time; key omitted otherwise. Old app
                               // builds ignore it.
    "topicHint":      String?  // ADDITIVE (sections, 2026-10-18): the Topic raw value ("business", "sports", "tech",
                               // "scienceHealth", "climate", "arts", "books", "food", "travel", "style", "realEstate",
                               // "obituaries") of the TOPIC FEED the article was fetched through; key omitted for an
                               // article from a main-news feed, so a bundle with no topic feeds is byte-for-byte the old
                               // shape. Old app builds ignore it; new builds file the story under that topic and count it
                               // against its own daily allowance (see "Topic feeds" below).
  }
  ```
- Topic feeds (sections, 2026-10-18): a feed in the vendored catalog may declare `FeedEndpoint.topicHint` (a Topic raw
  value) and `FeedEndpoint.maxPerDay` (default 10). The compiler tags every article such a feed supplies with the hint
  (`CompiledArticle.topicHint` in state, `topicHint` in the bundle), and gives each topic feed its OWN cap of
  `topicMaxPerDay` new items per run, newest first (feed order). Topic items do not count against
  `maxItemsPerSourcePerRun`, which now limits a source's MAIN feeds only: a busy topic feed cannot crowd out the main
  feeds, and a source whose main feeds fill the cap still compiles its topic feeds (they are listed after the main feeds,
  and the main cap used to end the whole survey). A topic feed that hits its cap withholds only its own feed
  conditional, so the next run re-fetches it and drains the rest. The first feed to see a guid wins, as ever: a story
  in both a main feed and a topic feed is compiled once, through the main feed, with no hint. The vendored `ArticleGate`
  also runs three quality rules here: pages whose web address has a gallery / live / video / audio / podcast / picture /
  add-to-cart / thefilter section (and CNBC's investingclub and pro) are skipped before any fetch; sports feeds drop
  betting and fantasy headlines; NPR's topic feeds need 150 words of body. A topic feed's old items (more than 7 days) are
  rejected by the phone's gate; the compiler's own 48-hour window already covers them. `maxPerDay` is the builder's per-run
  cap and, on the phone, only a CEILING: the phone's daily allowance for a (source, topic) follows the reader's "stories per
  source per day" setting (a quarter of it, never below 2: 15 -> 4, 25 -> 6, 40 -> 10, 60 -> 15), and the catalog's topic feeds
  declare none, so the builder's per-run cap is the default 10.
- **Rollout order for topic feeds: install the new app on Daniel's iPhone and iPad BEFORE pushing the builder change to
  `broadsheet-editions`.** Deploying the builder first is NOT harmless: it compiles topic feeds from outlets that are already
  in an old build's catalog (the Guardian, NPR, the Sun-Times, NY Post, Fox, ...), and an old build ingests those stories as
  ordinary news, under the outlet's first feed's place (the Guardian's is World) and inside its 25-a-day budget. Stories
  ingested that way stay on the device until they age out.
- Body block (inside `bodyBlocksJSON`): `{ "kind", "text"?, "imageURLString"?, "caption"?, "credit"?, "repeatsHero"? }`.
  `repeatsHero` is **ADDITIVE (2026-10-12, "hero shown once")**: `true` ONLY on an image block that shows the SAME
  photograph as the article's hero image (`topImageURL`); the key is omitted otherwise, so a body with no repeat
  encodes byte-for-byte as it always did and old app builds ignore the key. The block stays in the body (it is
  the only place the lead photo's caption and credit live); new app builds draw the photo once, as the hero, with
  that block's caption and credit under it, and do not draw (or download) the marked block itself -- unless the
  article ended up with no stored hero, when the block is drawn as usual. A body can carry more than one marked
  block (Vox puts the same photo at the top twice). See "Hero shown once" below.
- Server-side responsibilities: feed parse, full-text extraction, ArticleGate pass/fail,
  LanguageFilter, image download+resize (longest edge 1400px, JPEG q0.72, opaque) named by
  content sha. Phone-side (all EXISTING code paths, unchanged): categorization, subtopics,
  lean, ranking, editor scoring, per-day caps, dedup by guid.
- Hero choice (vendored `ContentExtractor`): the page's og:image, EXCEPT when it is a STAMPED share card: its URL
  carries a logo/text-stamping parameter (`overlay-*`, `watermark*`, imgix `txt*`/`mark*`/`blend*` -- every
  Guardian og:image is a signed 1200x630 crop with "The Guardian" burned in), or it is a BBC branded rendition
  (a `bbci.co.uk` URL with a whole path segment `branded_<letters>`: `ace/branded_news/1200/...` and
  `ace/branded_sport/1200/...` carry a "BBC NEWS"/"BBC SPORT" badge; 33 of 35 BBC og:images measured
  2026-10-12). For a stamped og:image the order is:
  1. the page's lead figure (the first usable `<figure>` before the first real body paragraph), taking its widest
     page-offered JPEG/PNG rendition (Guardian: 1400 px). First because it also ties the hero to the body: BBC
     sometimes uploads the og:image as a SEPARATE asset of the lead picture (a different uuid; confirmed on a real
     page 2026-10-12), which no URL comparison could match to the body's copy;
  2. else, where a badge-free twin can be derived by rule, that twin: BBC `.../ace/branded_<x>/<width>/...` ->
     `.../ace/standard/<width>/...` (verified live 2026-10-12: `standard/1200` answers 200 image/jpeg; the width is
     kept -- `standard/1400` is a 404). This keeps the editor's chosen photo, without the badge, on articles with
     no lead figure (a video-led story) instead of promoting a mid-article map or chart. Guardian's stamp is a
     signed query parameter, so no twin can be derived and its behavior is unchanged;
  3. else the first body photo; 4. else the og:image stays.
  The compiler downloads and re-hosts whatever the extractor chose. Articles already compiled keep
  their old hero until they age out of the 48 h window (state is never re-fetched).
- Hero shown once (2026-10-12): the reader draws the hero AND every body image, so wherever the hero photograph is
  also a body image it appeared twice (measured by comparing pixels on the live edition: BBC 29 of 35 articles,
  NPR 20 of 20, Vox 5 of 5, ABC News 5 of 8, ABC7 6 of 20, CBS 13 of 20 -- the repeat is a LATER block in 4 of
  them -- and every feed-text source, whose hero IS the first body image: Reason 17 of 17, Examiner 13 of 13).
  One rule in one place, `ContentExtractor.buildArticle` (the assembly point of the feed path, the page path and
  `upgradingHero`): after the hero is chosen, EVERY image block that shows the hero's photograph gets
  `repeatsHero = true` (see the contract above) and STAYS in the body. A block counts when its URL is exactly the
  hero's, when `samePhoto` says so (same host and same path, or a shared long asset id such as a UUID folder or a
  40-hex Guardian hash; for resizing proxies the `url=` original is compared; **hosts that differ only by
  trailing digits on their first label, `assets1`/`assets2`/`assets3.cbsnewsstatic.com`, are one host**), or when
  it is the block the page's lead figure produced (known by construction, so BBC's `standard/1024` copy of a
  photo whose og asset is another upload is still caught). Marks are recomputed from scratch on every assembly: a
  block never keeps a stale mark when the hero changes. Marked blocks whose URL differs from the hero's are left
  out of `allImageURLs` (the on-device crawl does not download a picture the reader will not draw). It does NOT
  catch a publisher that uploaded one picture twice under unrelated URLs (seen on NY Post and ABC7); that would
  need image comparison and is deliberately not attempted.
- BBC captions (2026-10-12): BBC puts a screen-reader label in every figcaption (`<span class="visually-hidden">
  Image caption, </span>`), so every BBC caption began "Image caption, ". One catalog rule drops it
  (`figcaption .visually-hidden` in the bbc `junkSelectors`). BBC's credit ("Image source, Getty Images") sits
  outside the figcaption and is not captured, before or after.
- Publish dates (2026-10-12): an article's `publishedAt` is the feed item's original publish time; when
  the feed has none, the PAGE's own `datePublished` / `article:published_time` (never a "modified" time);
  only when neither exists the compile time, flagged `dateIsEstimated` and counted per source in the run
  report ("dates: N estimated this run"). The vendored `FeedParser` now reads RFC 822 variants, ISO 8601
  with fractional seconds or `+0500` offsets (Sun-Times, WBEZ), `dc:date`, and zone-less stamps ONLY for a
  feed that declares its zone (`FeedEndpoint.zonelessDatesTimeZone`; NBC 5 = America/Chicago). Undated
  feed-text items reuse the one page fetch the hero upgrade already makes. A page date older than the
  window skips the item (negative-cached). Articles compiled BEFORE this change keep their stored date
  unless the feed still lists them with a real date that is EARLIER by more than a minute: then
  `publishedAt` is corrected in place (same guid, never re-fetched or duplicated) and the article leaves
  the edition if its real date is outside the window. Real-dated articles are never rewritten.
- Feed titles (vendored `FeedParser`): inline tags are stripped, entities decoded (every named reference
  in the HTML standard that ends with a semicolon -- 2,125 names in the generated, also-vendored
  `HTMLEntityTable.swift`, rebuilt by `scripts/gen_html_entity_table.py` -- plus decimal and hex, in one
  pass) and whitespace collapsed at parse time; article bodies are never touched. Unknown names and
  malformed sequences (`AT&T;`, `R&D`, `&#0;`) stay exactly as written. Authors and summaries get the same
  one-pass decode. The editions repo's copy of the package needs `HTMLEntityTable.swift` too.
- Feed parsing (vendored `FeedParser`): raw markup nested inside `<content>` / `<content:encoded>`
  is kept, serialized back into the content HTML. Sun-Times and WBEZ put their lead photo there as an
  unescaped `<img/>` before the escaped story text; it used to be dropped, leaving 45 of 54 Sun-Times
  and 8 of 19 WBEZ items with no hero (the rest with a 490x275 photo from mid-body). CDATA and fully
  escaped feeds are byte-identical to before.
- Feed-text hero upgrade: Sun-Times, WBEZ, ProPublica and Block Club (`EditionCompiler.
  pageHeroUpgradeSourceIDs`) carry only a small lead photo in the FEED (840 / 840 / 1149 / 1024 px).
  After an article passes the gate, the compiler fetches its page (one at a time inside the source's
  loop, like a page-extract source) and `ContentExtractor.upgradingHero` swaps in the widest rendition
  of the SAME photograph the page publishes (`<img>`/`<picture>` srcsets and schema.org `ImageObject`
  entries): smallest one that reaches 1400 px, never a 3200+ px camera original, never a different
  crop (aspect must match), never a different photo (identity check on the asset id / `url=` source).
  The feed's own copy of the lead stays in the body, marked `repeatsHero` (it used to be removed, which threw
  its caption and credit away). A failed page fetch keeps the feed hero; the run
  report counts "heroes upgraded from the page". Every other source is untouched.
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

- Requires an image tool: ImageMagick (`magick` or `convert`) or `sips` (any Mac). GitHub's
  Ubuntu 24.04 runners no longer preinstall ImageMagick, so the workflow installs it with
  `apt-get` and checks it is present before compiling. vips is deliberately not wired up —
  a third untested variant helps nobody.
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
cd aggregator && swift test   # 113 tests, no live network
```

Contract shape (golden round-trips, app-encoder-shape bodyBlocksJSON), vendored gate/language
parity spot-checks, extractor runs against the app suite's own fixtures
(`BroadsheetTests/Fixtures`), the logo-stamped hero fix (real Guardian fixtures through the
vendored extractor and through the compiler: the stamped share card is never downloaded, the
lead photo is; a clean og:image is untouched), the BBC badge and hero-shown-once rules (real BBC, NPR, Vox and CBS
captures through the vendored extractor and catalog: hero choice, which blocks are marked `repeatsHero`, the
`repeatsHero` JSON key present only when true, and a compile that downloads the badge-free twin and never the
badged share card), the BBC caption-label rule, end-to-end compiles against a fake HTTP client (steady-state
304s, negative-cache skips, windowing, image-failure text-first tolerance), pruning, resize
command builders (including the sips no-upscale guard), SHA-256 NIST vectors, drift
detection, and the total-loss hardening (mid-run state checkpoints observed on disk, a
fake-clock budget truncation, item-cap drain across two runs, concurrent pipe drains past
the 64KB buffer, and size-cap decisions plus compiler-level cap behavior).

## How the Actions workflow runs it

`github-workflow-edition.yml` (in this directory) is the canonical copy of the workflow that
is **installed** as `.github/workflows/edition.yml` in the public editions repo. Each run:

1. checkout + Swift setup on ubuntu, then `apt-get install imagemagick`,
2. `actions/cache` restores the state file and the output directory (so images and
   conditionals survive between runs; a cache miss just means one more expensive run —
   the compiler re-downloads retained articles' images from their recorded source URLs),
3. `swift run -c release compile-edition --out out --base-url <the Pages URL>`,
4. force-push `out/` to `gh-pages` as a single orphan commit (history stays one commit deep;
   Pages serves `edition.json.gz` + `images/`), retried up to 3 times because one transient
   HTTP 408 failed a run on 2026-09-29,
5. the `rearm` job waits 20 minutes on a free timer, then starts the next run (below).

Design notes to keep: the state file lives OUTSIDE the output directory (it must never be
published); the gh-pages push is `--force` with a fresh orphan commit each run; the
workflow-level concurrency guard means overlapping runs never double-push; publishing is
never skipped when nothing changed (the app reads the bundle's `generatedAt`).

### Self-chaining schedule (added 2026-10-11)

GitHub's free cron scheduler is best-effort. The workflow asked for every 30 minutes but
GitHub delivered about 4.4 runs a day (median gap 5.6 hours, worst 9.3 hours, measured over
7 days to 2026-10-11), and the app treats a bundle older than 90 minutes as stale and falls
back to a slow crawl. So the workflow now re-arms itself instead of trusting the cron:

- The `rearm` job runs after `compile` in the environment `edition-rearm`, which has a
  20-minute **wait timer** (repo Settings > Environments). A job held by a wait timer is
  "waiting", not running: it holds no runner and costs nothing. When the timer ends, the job
  dispatches the next run with the built-in `GITHUB_TOKEN` (`workflow_dispatch` is one of the
  two events that token may trigger). No external service and no new secret. A run lands
  about every 22-23 minutes (about 2 compile + 20 wait + queue time).
- The cron stays as a **watchdog** (`13,43 * * * *`, off the congested :00/:30 marks): if the
  chain ever breaks, the next cron delivery restarts it.
- Chains cannot multiply: the workflow-level concurrency group allows one run plus at most
  one pending run, and `rearm` skips its dispatch when another run is already queued (that
  run becomes the next link).
- Keep-alive against GitHub's rule that scheduled workflows in a public repo are disabled
  after 60 days without "repository activity" (the docs do not say what counts): the
  `keepalive` job makes one empty bot commit on `main` (built-in token, API only, no checkout)
  whenever the newest commit there is over 30 days old, so about monthly; every failure is
  logged and ignored, and it cannot loop (no `push` trigger; `GITHUB_TOKEN` commits start no
  runs). Test it with `gh workflow run edition.yml --repo dankelleghan-ops/broadsheet-editions
  -f force_keepalive=true`. `rearm` also still calls the "enable workflow" API each run, a
  harmless but unproven nudge.
- Each `rearm` run creates a deployment record, so the repo sidebar shows "Deployments".

**Restart by hand:** `gh workflow run edition.yml --repo dankelleghan-ops/broadsheet-editions`

**Switch it off:** disable the workflow (`gh workflow disable edition.yml --repo
dankelleghan-ops/broadsheet-editions`; a run that is already waiting sees this on wake-up and
does not dispatch), or delete the `rearm` job from the workflow (cron-only again). Cancelling
the in-flight run also stops the chain until the next watchdog delivery.

**Change the cadence** without touching code: set the wait timer, e.g.
`gh api -X PUT repos/dankelleghan-ops/broadsheet-editions/environments/edition-rearm -F wait_timer=15`.
Keep the cycle above about 7 minutes (GitHub Pages rebuilds on every push and has a soft
limit of 10 builds an hour).
