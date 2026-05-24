extension OpenAnythingCorpusBuilder {
  static func mostRecentTimelineEntries(
    _ entries: [TimelineEntry],
    limit: Int
  ) -> [TimelineEntry] {
    var result: [TimelineEntry] = []
    result.reserveCapacity(max(0, min(entries.count, limit)))
    forEachMostRecentTimelineEntry(entries, limit: limit) { entry in
      result.append(entry)
    }
    return result
  }

  static func forEachMostRecentTimelineEntry(
    _ entries: [TimelineEntry],
    limit: Int,
    _ consume: (TimelineEntry) -> Void
  ) {
    guard limit > 0 else { return }
    guard entries.count > limit else {
      emit(entries.sorted(by: isMoreRecent), to: consume)
      return
    }
    if entriesAreMostRecentFirst(entries) {
      emit(entries.prefix(limit), to: consume)
      return
    }
    if entriesAreOldestFirst(entries) {
      emit(entries.suffix(limit).reversed(), to: consume)
      return
    }
    emit(retainedMostRecentEntries(entries, limit: limit), to: consume)
  }

  private static func emit<Entries: Sequence>(
    _ entries: Entries,
    to consume: (TimelineEntry) -> Void
  ) where Entries.Element == TimelineEntry {
    for entry in entries {
      consume(entry)
    }
  }

  private static func retainedMostRecentEntries(
    _ entries: [TimelineEntry],
    limit: Int
  ) -> [TimelineEntry] {
    var recent: [TimelineEntry] = []
    recent.reserveCapacity(min(entries.count, limit))
    for entry in entries {
      retain(entry, in: &recent, limit: limit)
    }
    return recent
  }

  private static func retain(
    _ entry: TimelineEntry,
    in recent: inout [TimelineEntry],
    limit: Int
  ) {
    if recent.count == limit, let oldestKept = recent.last,
      !isMoreRecent(entry, than: oldestKept)
    {
      return
    }

    let insertionIndex =
      recent.firstIndex { kept in
        isMoreRecent(entry, than: kept)
      } ?? recent.count
    recent.insert(entry, at: insertionIndex)
    if recent.count > limit {
      recent.removeLast()
    }
  }

  private static func entriesAreMostRecentFirst(_ entries: [TimelineEntry]) -> Bool {
    for index in entries.indices.dropFirst()
    where isMoreRecent(entries[index], than: entries[entries.index(before: index)]) {
      return false
    }
    return true
  }

  private static func entriesAreOldestFirst(_ entries: [TimelineEntry]) -> Bool {
    for index in entries.indices.dropFirst()
    where isMoreRecent(entries[entries.index(before: index)], than: entries[index]) {
      return false
    }
    return true
  }

  private static func isMoreRecent(_ lhs: TimelineEntry, than rhs: TimelineEntry) -> Bool {
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt > rhs.recordedAt
    }
    return lhs.entryId < rhs.entryId
  }
}
