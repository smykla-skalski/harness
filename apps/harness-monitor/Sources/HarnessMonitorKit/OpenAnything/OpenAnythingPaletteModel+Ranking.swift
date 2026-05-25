import Foundation

extension OpenAnythingPaletteModel {
  /// Re-rank a results bundle so pinned items appear at the very top and
  /// recently-used items boost within their domain. Pinned records are
  /// gathered into a synthetic section that floats above the natural domain
  /// order; recency boosts apply within each domain.
  func applyRanking(
    to bundle: OpenAnythingResults,
    corpus: OpenAnythingPaletteCorpusCache?
  ) -> OpenAnythingResults {
    let contextActive = prioritizesContextDomain && contextDomain != nil
    guard showsPinned || showsRecent || contextActive else { return bundle }
    let orderedSections = contextOrderedSections(rankedSections(in: bundle))

    guard showsPinned else {
      return OpenAnythingResults(
        query: bundle.query,
        sections: orderedSections,
        domainTotals: bundle.domainTotals
      )
    }
    let pinned = pins.recordIDs
    guard !pinned.isEmpty else {
      return OpenAnythingResults(
        query: bundle.query,
        sections: orderedSections,
        domainTotals: bundle.domainTotals
      )
    }
    let pinnedSet = Set(pinned)

    let candidates = pinnedCandidates(
      in: orderedSections,
      corpus: corpus,
      pinned: pinnedSet
    )
    let pinnedHits = pinned.compactMap { candidates[$0] }

    guard !pinnedHits.isEmpty else {
      return OpenAnythingResults(
        query: bundle.query,
        sections: orderedSections,
        domainTotals: bundle.domainTotals
      )
    }

    let pinnedSection = OpenAnythingSection(
      id: "pinned",
      domain: .actions,
      title: "Pinned",
      systemImage: "pin",
      totalCount: pinnedHits.count,
      hits: pinnedHits
    )
    let filteredRest = orderedSections.map { section in
      OpenAnythingSection(
        domain: section.domain,
        hits: section.hits.filter { !pinnedSet.contains($0.id) }
      )
    }.filter { !$0.hits.isEmpty }

    return OpenAnythingResults(
      query: bundle.query,
      sections: [pinnedSection] + filteredRest,
      domainTotals: bundle.domainTotals
    )
  }

  /// Float the `contextDomain` section to the top of the natural domain order
  /// without dropping any other section. Unlike `scope`, this is a soft bias:
  /// when the palette opens from the Reviews view, Reviews-domain hits lead but
  /// Task Board, Sessions, and the rest still appear below. No-op when the
  /// preference is off, no context is set, or the section is already first.
  private func contextOrderedSections(
    _ sections: [OpenAnythingSection]
  ) -> [OpenAnythingSection] {
    guard prioritizesContextDomain, let contextDomain else { return sections }
    guard
      let matchIndex = sections.firstIndex(where: { $0.domain == contextDomain }),
      matchIndex != 0
    else {
      return sections
    }
    var reordered = sections
    let section = reordered.remove(at: matchIndex)
    reordered.insert(section, at: 0)
    return reordered
  }

  private func rankedSections(in bundle: OpenAnythingResults) -> [OpenAnythingSection] {
    guard showsRecent else { return bundle.sections }
    let recencyScores = recency.scoreMap(now: Date())
    guard !recencyScores.isEmpty else { return bundle.sections }
    return bundle.sections.map { section -> OpenAnythingSection in
      guard section.hits.contains(where: { (recencyScores[$0.id] ?? 0) > 0 }) else {
        return section
      }
      let sortedHits = section.hits.sorted { lhs, rhs in
        let lhsScore = recencyScores[lhs.id] ?? 0
        let rhsScore = recencyScores[rhs.id] ?? 0
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.score < rhs.score
      }
      return OpenAnythingSection(
        id: section.id,
        domain: section.domain,
        title: section.title,
        systemImage: section.systemImage,
        totalCount: section.totalCount,
        hits: sortedHits
      )
    }
  }

  private func pinnedCandidates(
    in sections: [OpenAnythingSection],
    corpus: OpenAnythingPaletteCorpusCache?,
    pinned: Set<String>
  ) -> [String: OpenAnythingHit] {
    var candidates: [String: OpenAnythingHit] = [:]
    candidates.reserveCapacity(pinned.count)
    sectionLoop: for section in sections {
      for hit in section.hits where pinned.contains(hit.id) {
        candidates[hit.id] = hit
        if candidates.count == pinned.count {
          break sectionLoop
        }
      }
    }
    guard let corpus else { return candidates }
    for recordID in pins.recordIDs where pinned.contains(recordID) && candidates[recordID] == nil {
      guard let record = corpus.record(id: recordID) else { continue }
      guard effectiveScope == nil || record.domain == effectiveScope else { continue }
      candidates[record.id] = OpenAnythingHit(
        record: record,
        highlights: .empty,
        score: 0
      )
    }
    return candidates
  }
}
