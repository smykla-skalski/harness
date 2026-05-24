extension OpenAnythingResults {
  public func hitCount(excludingCollapsedSections collapsedSectionIDs: Set<String>) -> Int {
    guard !collapsedSectionIDs.isEmpty else { return hitCount }
    var count = 0
    for section in sections where !collapsedSectionIDs.contains(section.id) {
      count += section.hits.count
    }
    return count
  }

  public func sectionCount(excludingCollapsedSections collapsedSectionIDs: Set<String>) -> Int {
    guard !collapsedSectionIDs.isEmpty else { return sections.count }
    var count = 0
    for section in sections where !collapsedSectionIDs.contains(section.id) {
      count += 1
    }
    return count
  }

  public func hasExactlyOneHit(
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> Bool {
    guard !collapsedSectionIDs.isEmpty else { return hasExactlyOneHit }
    var foundHit = false
    for section in sections where !collapsedSectionIDs.contains(section.id) {
      for _ in section.hits {
        guard !foundHit else { return false }
        foundHit = true
      }
    }
    return foundHit
  }

  func isEmpty(excludingCollapsedSections collapsedSectionIDs: Set<String>) -> Bool {
    firstHit(excludingCollapsedSections: collapsedSectionIDs) == nil
  }

  func firstHit(excludingCollapsedSections collapsedSectionIDs: Set<String>) -> OpenAnythingHit? {
    guard !collapsedSectionIDs.isEmpty else { return firstHit }
    for section in sections where !collapsedSectionIDs.contains(section.id) {
      if let hit = section.hits.first {
        return hit
      }
    }
    return nil
  }

  func hit(
    id: String,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> OpenAnythingHit? {
    guard !collapsedSectionIDs.isEmpty else { return hit(id: id) }
    for section in sections where !collapsedSectionIDs.contains(section.id) {
      if let hit = section.hits.first(where: { $0.id == id }) {
        return hit
      }
    }
    return nil
  }

  func containsHit(id: String, excludingCollapsedSections collapsedSectionIDs: Set<String>) -> Bool
  {
    hit(id: id, excludingCollapsedSections: collapsedSectionIDs) != nil
  }

  func hitID(
    movingFrom selectedHitID: String?,
    by delta: Int,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    guard !collapsedSectionIDs.isEmpty else {
      return hitID(movingFrom: selectedHitID, by: delta)
    }
    if delta == 0 {
      return selectedHitID.flatMap {
        hit(id: $0, excludingCollapsedSections: collapsedSectionIDs)?.id
      } ?? firstHit(excludingCollapsedSections: collapsedSectionIDs)?.id
    }
    if delta == 1 {
      return hitIDAfter(selectedHitID, excludingCollapsedSections: collapsedSectionIDs)
    }
    if delta == -1 {
      return hitIDBefore(selectedHitID, excludingCollapsedSections: collapsedSectionIDs)
    }
    return hitIDByOffset(
      movingFrom: selectedHitID,
      by: delta,
      excludingCollapsedSections: collapsedSectionIDs
    )
  }

  public func firstHitIDInVisibleSection(
    movingFrom selectedHitID: String?,
    bySection delta: Int,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    let currentIndex = currentVisibleSectionIndex(
      containing: selectedHitID,
      excludingCollapsedSections: collapsedSectionIDs
    )
    let count = visibleSectionCount(excludingCollapsedSections: collapsedSectionIDs)
    guard count > 0 else { return nil }
    let nextIndex = ((currentIndex + delta) % count + count) % count
    return firstHitIDInVisibleSection(
      at: nextIndex,
      excludingCollapsedSections: collapsedSectionIDs
    )
  }

  public func firstHitIDInVisibleSection(
    at index: Int,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    guard index >= 0 else { return nil }
    var visibleIndex = 0
    for section in sections where isVisibleSection(section, collapsedSectionIDs) {
      if visibleIndex == index {
        return section.hits.first?.id
      }
      visibleIndex += 1
    }
    return nil
  }

  private func hitIDAfter(
    _ selectedHitID: String?,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    var firstID: String?
    var secondID: String?
    var lastID: String?
    var selectedFound = false
    var returnNext = false

    for section in sections where !collapsedSectionIDs.contains(section.id) {
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

  private func hitIDBefore(
    _ selectedHitID: String?,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    var firstID: String?
    var previousID: String?

    for section in sections where !collapsedSectionIDs.contains(section.id) {
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

  private func hitIDByOffset(
    movingFrom selectedHitID: String?,
    by delta: Int,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    guard let selectedHitID else {
      return hitIDFromStart(by: delta, excludingCollapsedSections: collapsedSectionIDs)
    }
    if delta < 0 {
      let offset = delta == Int.min ? Int.max : -delta
      return hitIDBefore(
        selectedHitID,
        offset: offset,
        excludingCollapsedSections: collapsedSectionIDs
      )
    }
    return hitIDAfter(
      selectedHitID,
      offset: delta,
      excludingCollapsedSections: collapsedSectionIDs
    )
  }

  private func hitIDAfter(
    _ selectedHitID: String,
    offset: Int,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    guard offset > 0 else {
      return hit(id: selectedHitID, excludingCollapsedSections: collapsedSectionIDs)?.id
        ?? hitIDFromStart(by: 0, excludingCollapsedSections: collapsedSectionIDs)
    }

    let fallbackIndex = offset
    var fallbackID: String?
    var lastID: String?
    var remainingForward: Int?
    var index = 0

    for section in sections where !collapsedSectionIDs.contains(section.id) {
      for hit in section.hits {
        if index == fallbackIndex {
          fallbackID = hit.id
        }

        if let remaining = remainingForward {
          if remaining == 1 {
            return hit.id
          }
          remainingForward = remaining - 1
        }

        if hit.id == selectedHitID {
          remainingForward = offset
        }

        lastID = hit.id
        index += 1
      }
    }

    if remainingForward != nil {
      return lastID
    }
    return fallbackID ?? lastID
  }

  private func hitIDBefore(
    _ selectedHitID: String,
    offset: Int,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    var previousIDs: [String] = []
    previousIDs.reserveCapacity(min(offset, 64))
    var oldestPreviousIndex = 0
    var firstID: String?

    for section in sections where !collapsedSectionIDs.contains(section.id) {
      for hit in section.hits {
        if firstID == nil {
          firstID = hit.id
        }
        if hit.id == selectedHitID {
          guard previousIDs.count >= offset else {
            return firstID
          }
          return previousIDs[oldestPreviousIndex]
        }
        if previousIDs.count < offset {
          previousIDs.append(hit.id)
        } else {
          previousIDs[oldestPreviousIndex] = hit.id
          oldestPreviousIndex += 1
          if oldestPreviousIndex == offset {
            oldestPreviousIndex = 0
          }
        }
      }
    }

    return firstID
  }

  private func hitIDFromStart(
    by delta: Int,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> String? {
    let targetIndex = max(delta, 0)
    var index = 0
    var firstID: String?
    var lastID: String?

    for section in sections where !collapsedSectionIDs.contains(section.id) {
      for hit in section.hits {
        if firstID == nil {
          firstID = hit.id
        }
        if index == targetIndex {
          return hit.id
        }
        lastID = hit.id
        index += 1
      }
    }

    return delta < 0 ? firstID : lastID
  }

  private func currentVisibleSectionIndex(
    containing selectedHitID: String?,
    excludingCollapsedSections collapsedSectionIDs: Set<String>
  ) -> Int {
    guard let selectedHitID else { return 0 }
    var index = 0
    for section in sections where isVisibleSection(section, collapsedSectionIDs) {
      if section.hits.contains(where: { $0.id == selectedHitID }) {
        return index
      }
      index += 1
    }
    return 0
  }

  private func visibleSectionCount(excludingCollapsedSections collapsedSectionIDs: Set<String>)
    -> Int
  {
    var count = 0
    for section in sections where isVisibleSection(section, collapsedSectionIDs) {
      count += 1
    }
    return count
  }

  private func isVisibleSection(
    _ section: OpenAnythingSection,
    _ collapsedSectionIDs: Set<String>
  ) -> Bool {
    !collapsedSectionIDs.contains(section.id) && !section.hits.isEmpty
  }
}
