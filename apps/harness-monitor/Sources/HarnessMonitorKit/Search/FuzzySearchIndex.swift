import Foundation
import Fuse

private enum FuzzySearchScoreConstants {
  static let noPrefixRank = 1_000
  static let prefixRankScale = 1_000_000
  static let rawScoreScale = 100_000
}

public struct FuzzySearchField<Element>: Sendable {
  enum Accessor: Sendable {
    case single(@Sendable (Element) -> String?)
    case multiple(@Sendable (Element) -> [String])
  }

  public let name: String
  public let weight: Double
  public let highlightField: SearchHighlightField?
  public let prefixRank: Int?
  let accessor: Accessor

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

public struct FuzzySearchCandidate<Element: Sendable>: Sendable {
  public let item: Element
  /// Lower is better.
  public let score: Int
  public let rawScore: Double
  fileprivate let query: String
  fileprivate let matches: [FuseMatch]?
}

public struct FuzzySearchTopResults<Element: Sendable>: Sendable {
  public let results: [FuzzySearchResult<Element>]
  public let totalCount: Int

  public var isTruncated: Bool {
    totalCount > results.count
  }
}

private struct FuzzySearchPrefixValue: Sendable {
  let rank: Int
  let value: String
}

/// Shared weighted fuzzy-search wrapper around `Fuse.Search`.
public final class FuzzySearchIndex<Element: Sendable> {
  let fieldsByName: [String: FuzzySearchField<Element>]
  let highlightFields: [FuzzySearchField<Element>]
  let highlightOptions: FuseMatchOptions
  private let prefixFields: [FuzzySearchField<Element>]
  private let prefixValuesByIndex: [[FuzzySearchPrefixValue]]
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
    prefixValuesByIndex = Self.makePrefixValues(items: items, prefixFields: prefixFields)
    highlightFields = fields.filter { $0.highlightField != nil }
    highlightOptions = FuseMatchOptions(
      threshold: threshold,
      minMatchCharLength: minMatchCharLength,
      includeMatches: true,
      ignoreLocation: ignoreLocation,
      ignoreDiacritics: ignoreDiacritics
    )
    let keys = try fields.map(Self.fuseKey(for:))
    let options = try FuseOptions<Element>(
      ignoreDiacritics: ignoreDiacritics,
      includeMatches: false,
      includeScore: true,
      keys: keys,
      threshold: threshold,
      minMatchCharLength: minMatchCharLength,
      ignoreLocation: ignoreLocation
    )
    searcher = try Fuse.Search<Element>(items, options: options)
  }

  public func search(
    _ query: String,
    sortedBy areInIncreasingOrder: (
      (FuzzySearchResult<Element>, FuzzySearchResult<Element>) -> Bool
    )? = nil
  ) -> [FuzzySearchResult<Element>] {
    var results = unsortedSearch(query)
    results.sort(by: areInIncreasingOrder ?? Self.sortsBefore)
    return results
  }

  public func topResults(
    _ query: String,
    limit: Int,
    sortedBy areInIncreasingOrder: (
      (FuzzySearchCandidate<Element>, FuzzySearchCandidate<Element>) -> Bool
    )? = nil
  ) -> FuzzySearchTopResults<Element> {
    let limit = max(0, limit)
    guard limit > 0 else {
      return FuzzySearchTopResults(results: [], totalCount: 0)
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return FuzzySearchTopResults(results: [], totalCount: 0)
    }

    let sortedBy = areInIncreasingOrder ?? Self.candidateSortsBefore
    let normalizedQuery = Self.normalized(trimmed)
    let fuseResults = searcher.search(trimmed)
    var retained: [FuzzySearchCandidate<Element>] = []
    retained.reserveCapacity(min(limit, fuseResults.count))
    for result in fuseResults {
      let rawScore = result.score ?? 1
      let prefixRank = prefixRank(forRefIndex: result.refIndex, normalizedQuery: normalizedQuery)
      let normalizedScore =
        prefixRank * FuzzySearchScoreConstants.prefixRankScale
        + Int((rawScore * Double(FuzzySearchScoreConstants.rawScoreScale)).rounded())
      let candidate = FuzzySearchCandidate(
        item: result.item,
        score: normalizedScore,
        rawScore: rawScore,
        query: trimmed,
        matches: result.matches
      )
      Self.retain(candidate, in: &retained, limit: limit, sortedBy: sortedBy)
    }
    retained.sort(by: sortedBy)
    return FuzzySearchTopResults(
      results: retained.map(result),
      totalCount: fuseResults.count
    )
  }

  func unsortedSearch(_ query: String) -> [FuzzySearchResult<Element>] {
    var results: [FuzzySearchResult<Element>] = []
    forEachCandidate(query) { candidate in
      results.append(result(from: candidate))
    }
    return results
  }

  func unsortedCandidates(_ query: String) -> [FuzzySearchCandidate<Element>] {
    var results: [FuzzySearchCandidate<Element>] = []
    forEachCandidate(query) { candidate in
      results.append(candidate)
    }
    return results
  }

  func forEachCandidate(
    _ query: String,
    _ visit: (FuzzySearchCandidate<Element>) -> Void
  ) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let normalizedQuery = Self.normalized(trimmed)
    for result in searcher.search(trimmed) {
      let rawScore = result.score ?? 1
      let prefixRank = prefixRank(forRefIndex: result.refIndex, normalizedQuery: normalizedQuery)
      let normalizedScore =
        prefixRank * FuzzySearchScoreConstants.prefixRankScale
        + Int((rawScore * Double(FuzzySearchScoreConstants.rawScoreScale)).rounded())
      visit(
        FuzzySearchCandidate(
          item: result.item,
          score: normalizedScore,
          rawScore: rawScore,
          query: trimmed,
          matches: result.matches
        )
      )
    }
  }

  func result(from candidate: FuzzySearchCandidate<Element>) -> FuzzySearchResult<Element> {
    FuzzySearchResult(
      item: candidate.item,
      score: candidate.score,
      rawScore: candidate.rawScore,
      highlights: highlights(
        from: candidate.matches,
        fallbackQuery: candidate.query,
        item: candidate.item
      )
    )
  }

  private static func sortsBefore(
    _ lhs: FuzzySearchResult<Element>,
    _ rhs: FuzzySearchResult<Element>
  ) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score < rhs.score
    }
    return lhs.rawScore < rhs.rawScore
  }

  private static func candidateSortsBefore(
    _ lhs: FuzzySearchCandidate<Element>,
    _ rhs: FuzzySearchCandidate<Element>
  ) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score < rhs.score
    }
    return lhs.rawScore < rhs.rawScore
  }

  private static func retain(
    _ candidate: FuzzySearchCandidate<Element>,
    in retained: inout [FuzzySearchCandidate<Element>],
    limit: Int,
    sortedBy areInIncreasingOrder: (
      FuzzySearchCandidate<Element>,
      FuzzySearchCandidate<Element>
    ) -> Bool
  ) {
    guard retained.count == limit else {
      retained.append(candidate)
      return
    }

    var worstIndex = retained.startIndex
    for index in retained.indices.dropFirst()
    where areInIncreasingOrder(retained[worstIndex], retained[index]) {
      worstIndex = index
    }

    if areInIncreasingOrder(candidate, retained[worstIndex]) {
      retained[worstIndex] = candidate
    }
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

  private static func makePrefixValues(
    items: [Element],
    prefixFields: [FuzzySearchField<Element>]
  ) -> [[FuzzySearchPrefixValue]] {
    guard !prefixFields.isEmpty else { return [] }
    return items.map { item in
      var values: [FuzzySearchPrefixValue] = []
      values.reserveCapacity(prefixFields.count)
      for field in prefixFields {
        guard let rank = field.prefixRank else { continue }
        switch field.accessor {
        case .single(let get):
          appendPrefixValue(get(item), rank: rank, to: &values)
        case .multiple(let get):
          for value in get(item) {
            appendPrefixValue(value, rank: rank, to: &values)
          }
        }
      }
      return values
    }
  }

  private static func appendPrefixValue(
    _ rawValue: String?,
    rank: Int,
    to values: inout [FuzzySearchPrefixValue]
  ) {
    guard let rawValue else { return }
    let normalizedValue = normalized(rawValue)
    guard !normalizedValue.isEmpty else { return }
    values.append(FuzzySearchPrefixValue(rank: rank, value: normalizedValue))
  }

  private func prefixRank(forRefIndex refIndex: Int, normalizedQuery: String) -> Int {
    var best = FuzzySearchScoreConstants.noPrefixRank
    guard prefixValuesByIndex.indices.contains(refIndex) else { return best }
    for prefixValue in prefixValuesByIndex[refIndex]
    where prefixValue.value.hasPrefix(normalizedQuery) {
      best = min(best, prefixValue.rank)
    }
    return best
  }

  private static func normalized(_ value: String) -> String {
    value
      .folding(options: .diacriticInsensitive, locale: nil)
      .lowercased()
  }
}
