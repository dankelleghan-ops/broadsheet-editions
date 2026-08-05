#!/bin/bash
# sync-shared-sources.sh -- vendors the app's pipeline sources into the aggregator package.
#
# The aggregator (aggregator/Sources/AggregatorCore/Vendored/) compiles the EXACT files the
# iOS app compiles -- byte-for-byte copies, no forked logic. Portability (#if canImport
# guards for FoundationXML / NaturalLanguage) lives in the ORIGINALS under Broadsheet/, so a
# copy is always a plain `cp`. Anything the originals reference that is app-only (Prefs,
# DiagnosticsLog) is satisfied by small shims in AggregatorCore/Shims.swift -- shims provide
# SYMBOLS, never alternative pipeline logic.
#
# DRIFT RULE: if an original changes, the vendored copy is stale until this script re-runs.
# Drift is detectable, never silent:
#   - MANIFEST.sha256 records the checksum of every vendored file at sync time.
#   - `./sync-shared-sources.sh --check` exits non-zero if any vendored copy no longer
#     matches its original (or the manifest).
#   - AggregatorCoreTests.VendoredSourceDriftTests does the same comparison on every
#     `swift test` run.
#
# Usage:
#   ./sync-shared-sources.sh          # copy originals -> Vendored/, rewrite MANIFEST.sha256
#   ./sync-shared-sources.sh --check  # verify no drift; exit 1 and name the file if any

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$SCRIPT_DIR/Sources/AggregatorCore/Vendored"
MANIFEST="$DEST/MANIFEST.sha256"

# Repo-relative paths of every shared source. Keep in lockstep with
# VendoredSourceDriftTests.sharedSourcePaths.
FILES=(
  "Broadsheet/Sources/SourceCatalog.swift"
  "Broadsheet/Pipeline/FeedParser.swift"
  "Broadsheet/Pipeline/ContentExtractor.swift"
  "Broadsheet/Pipeline/ArticleGate.swift"
  "Broadsheet/Pipeline/LanguageFilter.swift"
  "Broadsheet/Models/CoreTypes.swift"
  "Broadsheet/Models/ArticleCategory.swift"
  "Broadsheet/Support/AttributionText.swift"
)

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [[ "${1:-}" == "--check" ]]; then
  status=0
  for rel in "${FILES[@]}"; do
    name="$(basename "$rel")"
    src="$REPO_ROOT/$rel"
    dst="$DEST/$name"
    if [[ ! -f "$dst" ]]; then
      echo "DRIFT: $name has no vendored copy -- run sync-shared-sources.sh" >&2
      status=1
      continue
    fi
    if ! cmp -s "$src" "$dst"; then
      echo "DRIFT: $rel differs from its vendored copy -- run sync-shared-sources.sh" >&2
      status=1
    fi
    if [[ -f "$MANIFEST" ]] && ! grep -q "$(sha "$dst")  $rel" "$MANIFEST"; then
      echo "DRIFT: MANIFEST.sha256 is stale for $rel -- run sync-shared-sources.sh" >&2
      status=1
    fi
  done
  if [[ ! -f "$MANIFEST" ]]; then
    echo "DRIFT: MANIFEST.sha256 missing -- run sync-shared-sources.sh" >&2
    status=1
  fi
  [[ $status -eq 0 ]] && echo "sync-shared-sources: no drift ($((${#FILES[@]})) files clean)"
  exit $status
fi

mkdir -p "$DEST"
: > "$MANIFEST.tmp"
for rel in "${FILES[@]}"; do
  src="$REPO_ROOT/$rel"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: missing original $rel" >&2
    exit 1
  fi
  cp "$src" "$DEST/$(basename "$rel")"
  echo "$(sha "$src")  $rel" >> "$MANIFEST.tmp"
done
mv "$MANIFEST.tmp" "$MANIFEST"
echo "sync-shared-sources: vendored ${#FILES[@]} files into ${DEST#"$REPO_ROOT"/}"
