import Foundation
import Fuse

private enum FuzzySearchScoreConstants {
  static let noPrefixRank = 1_000
  static let prefixRankScale = 1_000_000
  static let rawScoreScale = 100_000
}

public struct FuzzySearchField<Element>: Sendable {
  fileprivate enum Accessor: Sendable {
    case single(@Sendable (Element) -> String?)
    case multiple(@Sendable (Element) -> [String])
  }

  public let name: String
  public let weight: Double
  public let highlightField: SearchHighlightField?
  public let prefixRank: Int?
  fileprivate let accessor: Accessor

  public static func single(
    _ name: String,
    weight: Double,
    highlightField: SearchHighlightField? = nil,
    prefixRank: Int? = nil,
    get: @escaping @Sendable (Element) -> String?
  ) -> Self {
    Self(
      name: name,
      weight: weight,
      highlightField: highlightField,
      prefixRank: prefixRank,
      accessor: .single(get)
    )
  }

  public static func multiple(
    _ name: String,
    weight: Double,
    highlightField: SearchHighlightField? = nil,
    prefixRank: Int? = nil,
    get: @escaping @Sendable (Element) -> [String]
  ) -> Self {
    Self(
      name: name,
      weight: weight,
      highlightField: highlightField,
      prefixRank: prefixRank,
      accessor: .multiple(get)
    )
  }
}

public struct FuzzySearchResult<Element: Sendable>: Sendable {
  public let item: Element
  /// Lower is better.
  public let score: Int
  public let rawScore: Double
  public let highlights: SearchHighlights
}

/// Shared weighted fuzzy-search wrapper around `Fuse.Search`.
public final class FuzzySearchIndex<Element: Sendable> {
  private let fieldsByName: [String: FuzzySearchField<Element>]
  private let prefixFields: [FuzzySearchField<Element>]
  private let searcher: Fuse.Search<Element>

  public init(
    items: [Element],
    fields: [FuzzySearchField<Element>],
    threshold: Double = 0.4,
    ignoreLocation: Bool = true,
    ignoreDiacritics: Bool = true,
    minMatchCharLength: Int = 1
  ) throws {
    fieldsByName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
    prefixFields = fields.filter { $0.prefixRank != nil }
    let keys = try fields.map(Self.fuseKey(for:))
    let options = try FuseOptions<Element>(
      ignoreDiacritics: ignoreDiacritics,
      includeMatches: true,
      includeScore: true,
      keys: keys,
      threshold: threshold,
      minMatchCharLength: minMatchCharLength,
      ignoreLocation: ignoreLocation
    )
    searcher = try Fuse.Search<Element>(items, options: options)
  }

  public func search(_ query: String) -> [FuzzySearchResult<Element>] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let normalizedQuery = Self.normalized(trimmed)
    let fuseResults = searcher.search(trimmed)
    var results: [FuzzySearchResult<Element>] = []
    results.reserveCapacity(fuseResults.count)
    for result in fuseResults {
      let rawScore = result.score ?? 1
      let prefixRank = prefixRank(for: result.item, normalizedQuery: normalizedQuery)
      let normalizedScore =
        prefixRank * FuzzySearchScoreConstants.prefixRankScale
        + Int((rawScore * Double(FuzzySearchScoreConstants.rawScoreScale)).rounded())
      results.append(
        FuzzySearchResult(
          item: result.item,
          score: normalizedScore,
          rawScore: rawScore,
          highlights: highlights(from: result.matches)
        )
      )
    }
    results.sort { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score < rhs.score
      }
      return lhs.rawScore < rhs.rawScore
    }
    return results
  }

  private static func fuseKey(
    for field: FuzzySearchField<Element>
  ) throws -> FuseKey<Element> {
    switch field.accessor {
    case .single(let get):
      try FuseKey(field.name, get: get, weight: field.weight)
    case .multiple(let get):
      try FuseKey(field.name, get: get, weight: field.weight)
    }
  }

  private func prefixRank(for item: Element, normalizedQuery: String) -> Int {
    var best = FuzzySearchScoreConstants.noPrefixRank
    for field in prefixFields {
      guard let rank = field.prefixRank else { continue }
      switch field.accessor {
      case .single(let get):
        guard let value = get(item) else { continue }
        if Self.normalized(value).hasPrefix(normalizedQuery) {
          best = min(best, rank)
        }
      case .multiple(let get):
        if get(item).contains(where: { Self.normalized($0).hasPrefix(normalizedQuery) }) {
          best = min(best, rank)
        }
      }
    }
    return best
  }

  private func highlights(from matches: [FuseMatch]?) -> SearchHighlights {
    guard let matches else { return .empty }
    var title: [SearchHighlightRange] = []
    var subtitle: [SearchHighlightRange] = []
    var trailing: [SearchHighlightRange] = []

    for match in matches {
      guard case .string(let keyName)? = match.key else { continue }
      guard let field = fieldsByName[keyName] else { continue }
      let ranges = match.indices.map { SearchHighlightRange(start: $0.start, end: $0.end) }
      switch field.highlightField {
      case .title:
        title.append(contentsOf: ranges)
      case .subtitle:
        subtitle.append(contentsOf: ranges)
      case .trailing:
        trailing.append(contentsOf: ranges)
      case nil:
        continue
      }
    }

    return SearchHighlights(
      title: Self.mergedRanges(title),
      subtitle: Self.mergedRanges(subtitle),
      trailing: Self.mergedRanges(trailing)
    )
  }

  private static func mergedRanges(
    _ ranges: [SearchHighlightRange]
  ) -> [SearchHighlightRange] {
    guard !ranges.isEmpty else { return [] }
    let sorted = ranges.sorted {
      if $0.start != $1.start {
        return $0.start < $1.start
      }
      return $0.end < $1.end
    }
    var merged: [SearchHighlightRange] = []
    merged.reserveCapacity(sorted.count)
    for range in sorted {
      guard let last = merged.last else {
        merged.append(range)
        continue
      }
      if range.start <= last.end + 1 {
        merged[merged.count - 1] = SearchHighlightRange(
          start: last.start,
          end: max(last.end, range.end)
        )
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  private static func normalized(_ value: String) -> String {
    value
      .folding(options: .diacriticInsensitive, locale: nil)
      .lowercased()
  }
}
