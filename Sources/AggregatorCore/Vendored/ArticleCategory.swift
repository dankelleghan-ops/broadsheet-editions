import Foundation

/// v1.1 category/section reconciliation (architect decision, 2026-07-27): categories are
/// PLACES, subtopics are TOPICS. v1 mixed places (chicago/us/world) with topics (politics,
/// business, sports, science & health, other), which collided with the new theme-subsection
/// concept. Every former topical category now folds into its place section, with the topical
/// dimension carried by `Article.subtopicRaw` (see `Subtopic`) instead.
///
/// `entertainment` is the one remaining non-place category: it's celebrity/tabloid content
/// (pagesix.com host, Fox entertainment/media), hidden by default as in v1, and deliberately
/// kept separate from the genuine arts/culture content that now routes to a place section's
/// Culture/Food & Culture theme (see the Culture != Entertainment note in SubtopicClassifier).
enum ArticleCategory: String, CaseIterable, Codable, Identifiable {
    case chicago, us, world, entertainment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chicago: "Chicago"
        case .us: "U.S."
        case .world: "World"
        case .entertainment: "Entertainment"
        }
    }
}
