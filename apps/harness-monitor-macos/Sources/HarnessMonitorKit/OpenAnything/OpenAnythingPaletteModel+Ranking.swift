import Foundation

extension OpenAnythingPaletteModel {
  /// Re-rank a results bundle so pinned items appear at the very top and
  /// recently-used items boost within their domain. Pinned records are
  /// gathered into a synthetic actions pseudo-section that floats above the
  /// natural domain order; recency boosts apply within each domain so the
  /// domain layout stays intuitive.
  func applyRanking(
    to bundle: OpenAnythingResults,
    records: [OpenAnythingRecord]?
  ) -> OpenAnythingResults {
    let pinned = pins.recordIDs
    let now = Date()

    let rankedSections = bundle.sections.map { section -> OpenAnythingSection in
      let sortedHits = section.hits.sorted { lhs, rhs in
        let lhsScore = recency.score(for: lhs.id, now: now)
        let rhsScore = recency.score(for: rhs.id, now: now)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.score < rhs.score
      }
      return OpenAnythingSection(domain: section.domain, hits: sortedHits)
    }

    guard !pinned.isEmpty else {
      return OpenAnythingResults(
        query: bundle.query,
        sections: rankedSections,
        domainTotals: bundle.domainTotals
      )
    }

    let candidates = pinnedCandidates(
      rankedSections: rankedSections,
      records: records,
      pinned: pinned
    )
    let pinnedHits = pinned.compactMap { id in
      candidates.first(where: { $0.id == id })
    }

    guard !pinnedHits.isEmpty else {
      return OpenAnythingResults(
        query: bundle.query,
        sections: rankedSections,
        domainTotals: bundle.domainTotals
      )
    }

    let pinnedSection = OpenAnythingSection(domain: .actions, hits: pinnedHits)
    let filteredRest = rankedSections.map { section in
      OpenAnythingSection(
        domain: section.domain,
        hits: section.hits.filter { !pinned.contains($0.id) }
      )
    }.filter { !$0.hits.isEmpty }

    return OpenAnythingResults(
      query: bundle.query,
      sections: [pinnedSection] + filteredRest,
      domainTotals: bundle.domainTotals
    )
  }

  private func pinnedCandidates(
    rankedSections: [OpenAnythingSection],
    records: [OpenAnythingRecord]?,
    pinned: Set<String>
  ) -> [OpenAnythingHit] {
    let allHits = rankedSections.flatMap(\.hits)
    if let records, allHits.isEmpty {
      return records.compactMap { record in
        guard pinned.contains(record.id) else { return nil }
        return OpenAnythingHit(record: record, highlights: .empty, score: 0)
      }
    }
    return allHits.filter { pinned.contains($0.id) }
  }
}
