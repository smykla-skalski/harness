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
    limitPerDomain: Int = 6,
    unboundedDomains: Set<OpenAnythingDomain> = []
  ) -> OpenAnythingResults {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .empty
    }
    let matches = index.search(trimmed).sorted(by: sortsBefore)
    let grouped = Dictionary(grouping: matches) { $0.item.domain }
    var totals: [OpenAnythingDomain: Int] = [:]
    let sections = Self.domainOrder.compactMap { domain -> OpenAnythingSection? in
      guard let domainMatches = grouped[domain], !domainMatches.isEmpty else {
        return nil
      }
      totals[domain] = domainMatches.count
      // Audit #25: when the user taps "Show all" on a section, the model
      // passes the domain through `unboundedDomains` and the index returns
      // every match for that domain instead of capping at limitPerDomain.
      let cap = unboundedDomains.contains(domain) ? domainMatches.count : max(0, limitPerDomain)
      let hits = domainMatches.prefix(cap).map { match in
        OpenAnythingHit(
          record: match.item,
          highlights: match.highlights,
          score: match.score
        )
      }
      return OpenAnythingSection(domain: domain, hits: Array(hits))
    }
    return OpenAnythingResults(query: trimmed, sections: sections, domainTotals: totals)
  }

  public func suggestedResults(
    limitPerDomain: Int = 5,
    unboundedDomains: Set<OpenAnythingDomain> = []
  ) -> OpenAnythingResults {
    let suggested = records.filter(\.isSuggested)
    let grouped = Dictionary(grouping: suggested) { $0.domain }
    var totals: [OpenAnythingDomain: Int] = [:]
    let sections = Self.domainOrder.compactMap { domain -> OpenAnythingSection? in
      guard let domainRecords = grouped[domain], !domainRecords.isEmpty else {
        return nil
      }
      totals[domain] = domainRecords.count
      let cap = unboundedDomains.contains(domain) ? domainRecords.count : max(0, limitPerDomain)
      let hits = domainRecords.prefix(cap).map { record in
        OpenAnythingHit(record: record, highlights: .empty, score: 0)
      }
      return OpenAnythingSection(domain: domain, hits: Array(hits))
    }
    return OpenAnythingResults(query: "", sections: sections, domainTotals: totals)
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
      // Building the Fuse index can only fail on bad regex options; falling
      // back to an empty index keeps the app launchable. Log and carry on so
      // a future Fuse upgrade that flips a corner case does not crash the
      // process at startup.
      HarnessMonitorLogger.store.warning(
        "Failed to build OpenAnythingIndex: \(String(describing: error), privacy: .public)"
      )
      guard let fallback = try? FuzzySearchIndex(items: [], fields: fields) else {
        fatalError("FuzzySearchIndex with empty items should never throw")
      }
      return fallback
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
