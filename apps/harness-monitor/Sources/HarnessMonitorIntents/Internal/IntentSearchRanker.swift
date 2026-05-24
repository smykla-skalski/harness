import Foundation
import HarnessMonitorKit

/// Re-ranks daemon-returned PR search results using the same field
/// weights as `OpenAnythingIndex`. The Open Anything palette in the
/// Mac app uses title 0.8, subtitle (repository) 0.45, trailing
/// (PR number) 0.25 so Spotlight intent results sorted differently
/// from what the user sees in the palette breaks the trust contract -
/// the order should match
///
/// Implementation is a small weighted scorer rather than pulling in
/// FuzzySearchIndex from HarnessMonitorKit. Daemon results already
/// represent the candidate set; we only reorder. Scoring rule per
/// field: case-insensitive token match against the lowercased query
/// substring, then bucketed to {prefix=1.0, contains=0.6, none=0.0}
/// and multiplied by the field weight. Total score sums across the
/// fields; ties keep their daemon-returned relative order (stable
/// sort preserved by `sorted(by:)`'s contract via index-tagged tuples)
public enum IntentSearchRanker {
  public static let titleWeight: Double = 0.8
  public static let subtitleWeight: Double = 0.45
  public static let trailingWeight: Double = 0.25

  /// Re-orders `items` by descending match score against `query`.
  /// Items that match nothing keep their original order at the tail
  public static func rank(
    items: [ReviewItem],
    query: String
  ) -> [ReviewItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return items }

    let indexed = items.enumerated().map { offset, item in
      (offset: offset, item: item, score: score(item: item, lowercasedQuery: trimmed))
    }
    let sorted = indexed.sorted { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.offset < rhs.offset
    }
    return sorted.map(\.item)
  }

  /// Computes a [0..1.5] score for one item. Higher is better. Exposed
  /// for tests that pin the scoring contract per field
  public static func score(item: ReviewItem, lowercasedQuery query: String) -> Double {
    let title = item.title.lowercased()
    let repo = item.repository.lowercased()
    let trailing = "\(item.repository.lowercased())#\(item.number)"

    return fieldScore(field: title, query: query) * titleWeight
      + fieldScore(field: repo, query: query) * subtitleWeight
      + fieldScore(field: trailing, query: query) * trailingWeight
  }

  /// 1.0 for a prefix match, 0.6 for a non-prefix substring match, 0.0
  /// for no match. Mirrors the bucketing FuzzySearchField applies via
  /// its prefixRank machinery (prefix rank 0 wins over rank 1 wins
  /// over no rank); using bucketed scores keeps the algorithm self-
  /// contained and deterministic without dragging FuzzySearchIndex
  /// into the IntentsExtension binary
  static func fieldScore(field: String, query: String) -> Double {
    guard !query.isEmpty, !field.isEmpty else { return 0 }
    if field.hasPrefix(query) { return 1.0 }
    if field.contains(query) { return 0.6 }
    return 0
  }
}
