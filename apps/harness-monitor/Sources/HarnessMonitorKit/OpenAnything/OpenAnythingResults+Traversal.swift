extension OpenAnythingResults {
  public var hitCount: Int {
    sections.reduce(into: 0) { count, section in
      count += section.hits.count
    }
  }

  public var hasExactlyOneHit: Bool {
    var foundHit = false
    for section in sections {
      for _ in section.hits {
        guard !foundHit else { return false }
        foundHit = true
      }
    }
    return foundHit
  }

  public func excludingHits(inCollapsedSections collapsedSectionIDs: Set<String>) -> Self {
    guard !collapsedSectionIDs.isEmpty else { return self }
    let visibleSections = sections.compactMap { section -> OpenAnythingSection? in
      guard !collapsedSectionIDs.contains(section.id) else { return nil }
      return section
    }
    return OpenAnythingResults(
      query: query,
      sections: visibleSections,
      domainTotals: domainTotals
    )
  }

  var firstHit: OpenAnythingHit? {
    sections.lazy.compactMap(\.hits.first).first
  }

  func hit(id: String) -> OpenAnythingHit? {
    for section in sections {
      if let hit = section.hits.first(where: { $0.id == id }) {
        return hit
      }
    }
    return nil
  }

  func containsHit(id: String) -> Bool {
    hit(id: id) != nil
  }

  func hitID(movingFrom selectedHitID: String?, by delta: Int) -> String? {
    if delta == 0 {
      return selectedHitID.flatMap { hit(id: $0)?.id } ?? firstHit?.id
    }
    if delta == 1 {
      return hitIDAfter(selectedHitID)
    }
    if delta == -1 {
      return hitIDBefore(selectedHitID)
    }
    return hitIDByOffset(movingFrom: selectedHitID, by: delta)
  }

  private func hitIDAfter(_ selectedHitID: String?) -> String? {
    var firstID: String?
    var secondID: String?
    var lastID: String?
    var selectedFound = false
    var returnNext = false

    for section in sections {
      for hit in section.hits {
        if firstID == nil {
          firstID = hit.id
        } else if secondID == nil {
          secondID = hit.id
        }
        if returnNext {
          return hit.id
        }
        if let selectedHitID, hit.id == selectedHitID {
          selectedFound = true
          returnNext = true
        }
        lastID = hit.id
      }
    }

    if selectedFound {
      return lastID
    }
    return secondID ?? firstID
  }

  private func hitIDBefore(_ selectedHitID: String?) -> String? {
    var firstID: String?
    var previousID: String?

    for section in sections {
      for hit in section.hits {
        if firstID == nil {
          firstID = hit.id
        }
        if let selectedHitID, hit.id == selectedHitID {
          return previousID ?? hit.id
        }
        previousID = hit.id
      }
    }

    return firstID
  }

  private func hitIDByOffset(movingFrom selectedHitID: String?, by delta: Int) -> String? {
    let total = hitCount
    guard total > 0 else { return nil }
    let currentIndex =
      selectedHitID.flatMap(indexOfHit) ?? 0
    let nextIndex = min(max(currentIndex + delta, 0), total - 1)
    return hit(at: nextIndex)?.id
  }

  private func indexOfHit(id: String) -> Int? {
    var index = 0
    for section in sections {
      for hit in section.hits {
        if hit.id == id {
          return index
        }
        index += 1
      }
    }
    return nil
  }

  private func hit(at flattenedIndex: Int) -> OpenAnythingHit? {
    var index = 0
    for section in sections {
      for hit in section.hits {
        if index == flattenedIndex {
          return hit
        }
        index += 1
      }
    }
    return nil
  }
}
