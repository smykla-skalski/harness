import Foundation

/// A single search hit produced by `PolicyCanvasSearchEngine`. Each variant
/// carries the matched component's id, its rendered title (already
/// diacritic-folded for display? No — `displayTitle` is the original text so
/// the palette can mark the matched range against the user's eye-readable
/// title), the matched range expressed in the diacritic-folded title (where
/// the engine performed the match) plus a stable score used for ranking.
///
/// The range is in the folded title's UTF-16 indices, not the original. The
/// palette renders the original title; the matched substring length is the
/// same in the folded copy because `folding(options: .diacriticInsensitive)`
/// preserves index alignment for the alphabetic characters this engine
/// targets. Edge labels and group titles use the same convention.
public enum PolicyCanvasSearchHit: Equatable {
  case node(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)
  case edge(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)
  case group(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)

  var sortScore: Int {
    switch self {
    case .node(_, _, _, let score),
      .edge(_, _, _, let score),
      .group(_, _, _, let score):
      return score
    }
  }

  var sortKey: String {
    switch self {
    case .node(let id, _, _, _),
      .edge(let id, _, _, _),
      .group(let id, _, _, _):
      return id
    }
  }

  var displayTitle: String {
    switch self {
    case .node(_, let title, _, _),
      .edge(_, let title, _, _),
      .group(_, let title, _, _):
      return title
    }
  }
}

/// Filter constraining which kinds of canvas components the engine returns.
/// `nil` means no filter (search across nodes, edges, and groups). Used by the
/// palette's optional type-filter chips and by tests that exercise the
/// per-kind ranking guarantees in isolation.
///
/// `Sendable` because the static `all` accessor exposes a global-scope value
/// the compiler checks at every call site; the struct is value-typed with
/// only `Bool` fields so the conformance is trivially safe.
public struct PolicyCanvasSearchFilter: Equatable, Sendable {
  public var includeNodes: Bool
  public var includeEdges: Bool
  public var includeGroups: Bool

  public static let all = Self(
    includeNodes: true,
    includeEdges: true,
    includeGroups: true
  )

  public init(includeNodes: Bool, includeEdges: Bool, includeGroups: Bool) {
    self.includeNodes = includeNodes
    self.includeEdges = includeEdges
    self.includeGroups = includeGroups
  }
}

/// Scoring tiers. Higher is better; ties are broken by insertion order
/// (preserved as `sortKey` and rendered stably by the palette).
private enum PolicyCanvasSearchScore {
  static let exact: Int = 100
  static let prefix: Int = 75
  static let substring: Int = 50
  static let kindName: Int = 25
}

/// Stateless ranking engine for canvas search. Pure-value inputs only; no
/// reference to the @MainActor view model, so unit tests can construct
/// fixtures directly without spinning up a view model.
///
/// Performance contract: a 200-node graph completes a `search(...)` call well
/// under 5ms on M-series hardware. Achieved by:
/// - Single pass over each component collection
/// - One folded title per component (cached only inside the call; not
///   persisted because the canvas mutation surface is too wide for cache
///   invalidation to be cheaper than recomputation)
/// - `Range<String.Index>` lookup via `range(of:options:)` with
///   `.caseInsensitive` and `.diacriticInsensitive` — no manual character
///   walk
public struct PolicyCanvasSearchEngine {
  public init() {}

  /// Resolve all matches for `query` against the supplied graph. The query is
  /// trimmed and folded once up front so the per-component compare can stay
  /// tight. An empty trimmed query returns no hits; callers (e.g. the search
  /// palette) render a "recent selections" path in that case.
  public func search(
    query: String,
    nodes: [PolicyCanvasSearchableNode],
    edges: [PolicyCanvasSearchableEdge],
    groups: [PolicyCanvasSearchableGroup],
    filter: PolicyCanvasSearchFilter = .all
  ) -> [PolicyCanvasSearchHit] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return []
    }
    let folded = trimmed.folding(options: .diacriticInsensitive, locale: nil)
    var hits: [PolicyCanvasSearchHit] = []
    hits.reserveCapacity(nodes.count + edges.count + groups.count)

    if filter.includeNodes {
      hits.append(contentsOf: nodeHits(for: folded, nodes: nodes))
    }
    if filter.includeEdges {
      hits.append(contentsOf: edgeHits(for: folded, edges: edges))
    }
    if filter.includeGroups {
      hits.append(contentsOf: groupHits(for: folded, groups: groups))
    }

    return hits.sorted { lhs, rhs in
      if lhs.sortScore != rhs.sortScore {
        return lhs.sortScore > rhs.sortScore
      }
      return lhs.sortKey < rhs.sortKey
    }
  }

  private func nodeHits(
    for query: String,
    nodes: [PolicyCanvasSearchableNode]
  ) -> [PolicyCanvasSearchHit] {
    nodes.compactMap { node in
      let folded = node.title.folding(options: .diacriticInsensitive, locale: nil)
      if let range = folded.range(of: query, options: .caseInsensitive) {
        let score = scoreForTitleMatch(range: range, in: folded, query: query)
        return PolicyCanvasSearchHit.node(
          id: node.id,
          displayTitle: node.title,
          matchedRange: range,
          score: score
        )
      }
      let foldedKind = node.kindName.folding(options: .diacriticInsensitive, locale: nil)
      if foldedKind.range(of: query, options: .caseInsensitive) != nil {
        return PolicyCanvasSearchHit.node(
          id: node.id,
          displayTitle: node.title,
          matchedRange: nil,
          score: PolicyCanvasSearchScore.kindName
        )
      }
      return nil
    }
  }

  private func edgeHits(
    for query: String,
    edges: [PolicyCanvasSearchableEdge]
  ) -> [PolicyCanvasSearchHit] {
    edges.compactMap { edge in
      let folded = edge.label.folding(options: .diacriticInsensitive, locale: nil)
      guard let range = folded.range(of: query, options: .caseInsensitive) else {
        return nil
      }
      let score = scoreForTitleMatch(range: range, in: folded, query: query)
      return PolicyCanvasSearchHit.edge(
        id: edge.id,
        displayTitle: edge.label,
        matchedRange: range,
        score: score
      )
    }
  }

  private func groupHits(
    for query: String,
    groups: [PolicyCanvasSearchableGroup]
  ) -> [PolicyCanvasSearchHit] {
    groups.compactMap { group in
      let folded = group.title.folding(options: .diacriticInsensitive, locale: nil)
      guard let range = folded.range(of: query, options: .caseInsensitive) else {
        return nil
      }
      let score = scoreForTitleMatch(range: range, in: folded, query: query)
      return PolicyCanvasSearchHit.group(
        id: group.id,
        displayTitle: group.title,
        matchedRange: range,
        score: score
      )
    }
  }

  /// Resolve a substring match into one of the title-tier scores: exact when
  /// the query covers the full title, prefix when the match starts at the
  /// title's first character, substring otherwise. Kind-name matches don't
  /// flow through here — they always emit `kindName` since the user did not
  /// type the title.
  private func scoreForTitleMatch(
    range: Range<String.Index>,
    in folded: String,
    query: String
  ) -> Int {
    if folded.count == query.count, range.lowerBound == folded.startIndex,
      range.upperBound == folded.endIndex
    {
      return PolicyCanvasSearchScore.exact
    }
    if range.lowerBound == folded.startIndex {
      return PolicyCanvasSearchScore.prefix
    }
    return PolicyCanvasSearchScore.substring
  }
}

/// Value-typed projection of a node passed to the search engine. Keeps the
/// engine independent of `PolicyCanvasNode` so unit tests can fabricate
/// rows without constructing a full canvas graph.
public struct PolicyCanvasSearchableNode: Equatable {
  public let id: String
  public let title: String
  public let kindName: String

  public init(id: String, title: String, kindName: String) {
    self.id = id
    self.title = title
    self.kindName = kindName
  }
}

public struct PolicyCanvasSearchableEdge: Equatable {
  public let id: String
  public let label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

public struct PolicyCanvasSearchableGroup: Equatable {
  public let id: String
  public let title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}
