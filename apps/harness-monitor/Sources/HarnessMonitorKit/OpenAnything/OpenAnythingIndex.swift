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
    unboundedDomains: Set<OpenAnythingDomain> = [],
    scope: OpenAnythingDomain? = nil
  ) -> OpenAnythingResults {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .empty
    }
    // Count every match for "Show all" while retaining only the visible cap
    // unless the domain is explicitly unbounded.
    let visibleLimit = max(0, limitPerDomain)
    var totals: [OpenAnythingDomain: Int] = [:]
    var candidatesByDomain: [OpenAnythingDomain: [FuzzySearchCandidate<OpenAnythingRecord>]] = [:]
    index.forEachCandidate(trimmed) { match in
      let domain = match.item.domain
      if let scope, domain != scope { return }
      totals[domain, default: 0] += 1
      retainSearchCandidate(
        match,
        in: domain,
        visibleLimit: visibleLimit,
        unboundedDomains: unboundedDomains,
        candidatesByDomain: &candidatesByDomain
      )
    }
    let sectionDomains = sectionDomains(scopedTo: scope)
    let sections = sectionDomains.compactMap { domain -> OpenAnythingSection? in
      guard totals[domain] != nil else {
        return nil
      }
      let hits = (candidatesByDomain[domain] ?? [])
        .sorted(by: candidateSortsBefore)
        .map { candidate in
          let result = index.result(from: candidate)
          return OpenAnythingHit(
            record: result.item,
            highlights: result.highlights,
            score: result.score
          )
        }
      return OpenAnythingSection(
        domain: domain,
        hits: hits
      )
    }
    return OpenAnythingResults(query: trimmed, sections: sections, domainTotals: totals)
  }

  public func suggestedResults(
    limitPerDomain: Int = 5,
    unboundedDomains: Set<OpenAnythingDomain> = [],
    scope: OpenAnythingDomain? = nil
  ) -> OpenAnythingResults {
    // Count every suggested record for "Show all" while retaining only the
    // visible cap unless the domain is explicitly unbounded.
    let visibleLimit = max(0, limitPerDomain)
    var totals: [OpenAnythingDomain: Int] = [:]
    var hitsByDomain: [OpenAnythingDomain: [OpenAnythingHit]] = [:]
    for record in records where record.isSuggested {
      let domain = record.domain
      if let scope, domain != scope { continue }
      totals[domain, default: 0] += 1
      let cap = unboundedDomains.contains(domain) ? Int.max : visibleLimit
      if (hitsByDomain[domain]?.count ?? 0) < cap {
        hitsByDomain[domain, default: []].append(
          OpenAnythingHit(record: record, highlights: .empty, score: 0)
        )
      }
    }
    let sections = sectionDomains(scopedTo: scope).compactMap { domain -> OpenAnythingSection? in
      guard totals[domain] != nil else {
        return nil
      }
      return OpenAnythingSection(domain: domain, hits: hitsByDomain[domain] ?? [])
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

  private func sectionDomains(scopedTo scope: OpenAnythingDomain?) -> [OpenAnythingDomain] {
    scope.map { [$0] } ?? OpenAnythingDomain.displayOrder
  }

  private func retainSearchCandidate(
    _ candidate: FuzzySearchCandidate<OpenAnythingRecord>,
    in domain: OpenAnythingDomain,
    visibleLimit: Int,
    unboundedDomains: Set<OpenAnythingDomain>,
    candidatesByDomain: inout [OpenAnythingDomain: [FuzzySearchCandidate<OpenAnythingRecord>]]
  ) {
    guard unboundedDomains.contains(domain) || visibleLimit > 0 else { return }
    guard !unboundedDomains.contains(domain) else {
      candidatesByDomain[domain, default: []].append(candidate)
      return
    }
    retainBoundedSearchCandidate(
      candidate,
      visibleLimit: visibleLimit,
      candidates: &candidatesByDomain[domain, default: []]
    )
  }

  private func retainBoundedSearchCandidate(
    _ candidate: FuzzySearchCandidate<OpenAnythingRecord>,
    visibleLimit: Int,
    candidates: inout [FuzzySearchCandidate<OpenAnythingRecord>]
  ) {
    if candidates.isEmpty {
      candidates.reserveCapacity(visibleLimit)
    }
    if candidates.count < visibleLimit {
      candidates.append(candidate)
      return
    }
    guard
      let worstIndex = candidates.indices.max(
        by: { candidateSortsBefore(candidates[$0], candidates[$1]) }
      ),
      candidateSortsBefore(candidate, candidates[worstIndex])
    else { return }
    candidates[worstIndex] = candidate
  }

  private func candidateSortsBefore(
    _ lhs: FuzzySearchCandidate<OpenAnythingRecord>,
    _ rhs: FuzzySearchCandidate<OpenAnythingRecord>
  ) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score < rhs.score
    }
    return lhs.item.title.localizedCompare(rhs.item.title) == .orderedAscending
  }
}
