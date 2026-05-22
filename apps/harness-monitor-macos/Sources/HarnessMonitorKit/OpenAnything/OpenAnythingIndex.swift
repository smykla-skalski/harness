import Foundation

public actor OpenAnythingIndex {
  private static let fields: [FuzzySearchField<OpenAnythingRecord>] = [
    .single("title", weight: 0.8, highlightField: .title, prefixRank: 0) { $0.title },
    .single("subtitle", weight: 0.45, highlightField: .subtitle, prefixRank: 1) {
      $0.subtitle
    },
    .single("trailing", weight: 0.25, highlightField: .trailing, prefixRank: 2) {
      $0.trailing
    },
    .single("searchBody", weight: 0.3) { $0.searchBody.isEmpty ? nil : $0.searchBody },
  ]

  private static let domainOrder: [OpenAnythingDomain] = [
    .actions,
    .windows,
    .settings,
    .sessions,
    .taskBoard,
    .decisions,
    .reviews,
    .loadedSession,
  ]

  private var records: [OpenAnythingRecord] = []
  private var index = OpenAnythingIndex.makeIndex(records: [])

  public init() {}

  public func replace(records: [OpenAnythingRecord]) {
    self.records = records
    index = Self.makeIndex(records: records)
  }

  public func search(
    query: String,
    limitPerDomain: Int = 6
  ) -> OpenAnythingResults {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .empty
    }
    let matches = index.search(trimmed).sorted(by: sortsBefore)
    let grouped = Dictionary(grouping: matches) { $0.item.domain }
    let sections = Self.domainOrder.compactMap { domain -> OpenAnythingSection? in
      guard let domainMatches = grouped[domain], !domainMatches.isEmpty else {
        return nil
      }
      let hits = domainMatches.prefix(max(0, limitPerDomain)).map { match in
        OpenAnythingHit(
          record: match.item,
          highlights: match.highlights,
          score: match.score
        )
      }
      return OpenAnythingSection(domain: domain, hits: Array(hits))
    }
    return OpenAnythingResults(query: trimmed, sections: sections)
  }

  public func suggestedResults(limitPerDomain: Int = 5) -> OpenAnythingResults {
    let suggested = records.filter(\.isSuggested)
    let grouped = Dictionary(grouping: suggested) { $0.domain }
    let sections = Self.domainOrder.compactMap { domain -> OpenAnythingSection? in
      guard let domainRecords = grouped[domain], !domainRecords.isEmpty else {
        return nil
      }
      let hits = domainRecords.prefix(max(0, limitPerDomain)).map { record in
        OpenAnythingHit(record: record, highlights: .empty, score: 0)
      }
      return OpenAnythingSection(domain: domain, hits: Array(hits))
    }
    return OpenAnythingResults(query: "", sections: sections)
  }

  public func recordCount() -> Int {
    records.count
  }

  private static func makeIndex(records: [OpenAnythingRecord]) -> FuzzySearchIndex<
    OpenAnythingRecord
  > {
    do {
      return try FuzzySearchIndex(items: records, fields: fields)
    } catch {
      preconditionFailure("Failed to build OpenAnythingIndex: \(error)")
    }
  }

  private func sortsBefore(
    _ lhs: FuzzySearchResult<OpenAnythingRecord>,
    _ rhs: FuzzySearchResult<OpenAnythingRecord>
  ) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score < rhs.score
    }
    return lhs.item.title.localizedCompare(rhs.item.title) == .orderedAscending
  }
}
