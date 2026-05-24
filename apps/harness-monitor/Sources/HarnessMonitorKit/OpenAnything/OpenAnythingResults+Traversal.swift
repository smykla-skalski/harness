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
    guard let selectedHitID else {
      return hitIDFromStart(by: delta)
    }
    if delta < 0 {
      let offset = delta == Int.min ? Int.max : -delta
      return hitIDBefore(selectedHitID, offset: offset)
    }
    return hitIDAfter(selectedHitID, offset: delta)
  }

  private func hitIDAfter(_ selectedHitID: String, offset: Int) -> String? {
    guard offset > 0 else {
      return hit(id: selectedHitID)?.id ?? hitIDFromStart(by: 0)
    }

    let fallbackIndex = offset
    var fallbackID: String?
    var lastID: String?
    var remainingForward: Int?
    var index = 0

    for section in sections {
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

  private func hitIDBefore(_ selectedHitID: String, offset: Int) -> String? {
    var previousIDs: [String] = []
    previousIDs.reserveCapacity(min(offset, 64))
    var oldestPreviousIndex = 0
    var firstID: String?

    for section in sections {
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

  private func hitIDFromStart(by delta: Int) -> String? {
    let targetIndex = max(delta, 0)
    var index = 0
    var firstID: String?
    var lastID: String?

    for section in sections {
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
}
