extension OpenAnythingPaletteModel {
  static func suggestedResults(
    from suggestedRecords: [OpenAnythingRecord],
    limitPerDomain: Int,
    unboundedDomains: Set<OpenAnythingDomain>,
    scope: OpenAnythingDomain?
  ) -> OpenAnythingResults {
    let visibleLimit = max(0, limitPerDomain)
    var totals: [OpenAnythingDomain: Int] = [:]
    var hitsByDomain: [OpenAnythingDomain: [OpenAnythingHit]] = [:]
    for record in suggestedRecords {
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
    let sectionDomains = scope.map { [$0] } ?? OpenAnythingDomain.displayOrder
    let sections = sectionDomains.compactMap { domain -> OpenAnythingSection? in
      guard totals[domain] != nil else {
        return nil
      }
      return OpenAnythingSection(domain: domain, hits: hitsByDomain[domain] ?? [])
    }
    return OpenAnythingResults(query: "", sections: sections, domainTotals: totals)
  }
}
