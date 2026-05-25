extension OpenAnythingResults {
  func hit(id: String) -> OpenAnythingHit? {
    guard let location = hitLocationsByID[id] else { return nil }
    guard sections.indices.contains(location.sectionIndex) else { return nil }
    let hits = sections[location.sectionIndex].hits
    guard hits.indices.contains(location.hitIndex) else { return nil }
    return hits[location.hitIndex]
  }

  func containsHit(id: String) -> Bool {
    hitLocationsByID[id] != nil
  }

  func hitID(movingFrom selectedHitID: String?, by delta: Int) -> String? {
    guard !hitIDs.isEmpty else { return nil }
    guard delta != 0 else {
      if let selectedHitID, hitLocationsByID[selectedHitID] != nil {
        return selectedHitID
      }
      return hitIDs[0]
    }
    guard
      let selectedHitID,
      let currentIndex = hitLocationsByID[selectedHitID]?.resultIndex
    else {
      return hitIDFromStart(by: delta)
    }
    if delta < 0 {
      let offset = delta == Int.min ? Int.max : -delta
      guard offset <= currentIndex else { return hitIDs[0] }
      return hitIDs[currentIndex - offset]
    }

    guard delta < hitIDs.count, currentIndex < hitIDs.count - delta else {
      return hitIDs[hitIDs.count - 1]
    }
    return hitIDs[currentIndex + delta]
  }

  private func hitIDFromStart(by delta: Int) -> String? {
    guard delta >= 0 else { return hitIDs[0] }
    return hitIDs[min(delta, hitIDs.count - 1)]
  }
}
