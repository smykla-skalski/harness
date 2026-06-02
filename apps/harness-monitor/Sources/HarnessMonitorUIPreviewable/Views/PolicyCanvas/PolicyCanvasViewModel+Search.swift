import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  /// Scoring tiers used by `searchHits(query:limit:)`. Higher is better; ties
  /// are broken by stable component-id order. Kind-name matches always emit
  /// the `kindName` tier — they live below substring hits because the user
  /// did not type the title.
  fileprivate enum SearchScore {
    static let exact: Int = 100
    static let prefix: Int = 75
    static let substring: Int = 50
    static let kindName: Int = 25
  }

  /// Resolve all matches for `query` against the canvas graph. The query is
  /// trimmed and diacritic-folded once up front so the per-component compare
  /// stays tight (`String.folding(options:locale:)` plus one
  /// `range(of:options:)` with `.caseInsensitive`). An empty trimmed query
  /// returns no hits; callers (the search palette) render a recent-hits path
  /// in that case.
  ///
  /// `limit` caps the rendered count so a wildcard-like query on a 200-node
  /// graph does not paint a 200-row list. The default (`50`) is well above
  /// the palette's render budget so a follow-up that lifts the cap does not
  /// need a model-side change.
  ///
  /// Performance contract: a 200-node graph completes well under 5ms on
  /// M-series hardware. Achieved by a single pass over each collection plus
  /// per-component folded-title computation (cached only inside the call;
  /// the canvas mutation surface is too wide for a persisted cache to be
  /// cheaper than recomputation).
  func searchHits(query: String, limit: Int = 50) -> [PolicyCanvasSearchHit] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return []
    }
    let folded = trimmed.folding(options: .diacriticInsensitive, locale: nil)
    var hits: [PolicyCanvasSearchHit] = []
    hits.reserveCapacity(nodes.count + edges.count + groups.count)

    for node in nodes {
      let foldedTitle = node.title.folding(options: .diacriticInsensitive, locale: nil)
      if let range = foldedTitle.range(of: folded, options: .caseInsensitive) {
        let score = scoreForTitleMatch(range: range, in: foldedTitle, query: folded)
        hits.append(
          .node(id: node.id, displayTitle: node.title, matchedRange: range, score: score)
        )
        continue
      }
      let foldedKind = node.kind.title.folding(options: .diacriticInsensitive, locale: nil)
      if foldedKind.range(of: folded, options: .caseInsensitive) != nil {
        hits.append(
          .node(
            id: node.id,
            displayTitle: node.title,
            matchedRange: nil,
            score: SearchScore.kindName
          )
        )
      }
    }

    for edge in edges {
      let foldedLabel = edge.label.folding(options: .diacriticInsensitive, locale: nil)
      guard let range = foldedLabel.range(of: folded, options: .caseInsensitive) else {
        continue
      }
      let score = scoreForTitleMatch(range: range, in: foldedLabel, query: folded)
      hits.append(
        .edge(id: edge.id, displayTitle: edge.label, matchedRange: range, score: score)
      )
    }

    for group in groups {
      let foldedTitle = group.title.folding(options: .diacriticInsensitive, locale: nil)
      guard let range = foldedTitle.range(of: folded, options: .caseInsensitive) else {
        continue
      }
      let score = scoreForTitleMatch(range: range, in: foldedTitle, query: folded)
      hits.append(
        .group(id: group.id, displayTitle: group.title, matchedRange: range, score: score)
      )
    }

    let sorted = hits.sorted { lhs, rhs in
      if lhs.sortScore != rhs.sortScore {
        return lhs.sortScore > rhs.sortScore
      }
      return lhs.sortKey < rhs.sortKey
    }
    if sorted.count > limit {
      return Array(sorted.prefix(limit))
    }
    return sorted
  }

  /// Resolve a substring match into one of the title-tier scores: exact when
  /// the query covers the full title, prefix when the match starts at the
  /// title's first character, substring otherwise. Kind-name matches never
  /// flow through here — they always emit `kindName` since the user did not
  /// type the title.
  fileprivate func scoreForTitleMatch(
    range: Range<String.Index>,
    in folded: String,
    query: String
  ) -> Int {
    if folded.count == query.count, range.lowerBound == folded.startIndex,
      range.upperBound == folded.endIndex
    {
      return SearchScore.exact
    }
    if range.lowerBound == folded.startIndex {
      return SearchScore.prefix
    }
    return SearchScore.substring
  }
}
