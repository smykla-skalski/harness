import CoreGraphics

struct SessionTimelineTableHeightCacheSeed {
  let heightsByID: [String: CachedRowHeight]
}

@MainActor
enum SessionTimelineTableHeightCacheStore {
  private struct Entry {
    var rowSnapshotsByID: [String: SessionTimelineTableRowSnapshot]
    var heightsByID: [String: CachedRowHeight]
    let fontScale: CGFloat
    var accessIndex: UInt64
  }

  private static let fontScaleTolerance: CGFloat = 0.001
  private static let maximumSessionCount = 16

  private static var entries: [SessionTimelineContentIdentity: Entry] = [:]
  private static var accessCounter: UInt64 = 0

  static func restore(
    identity: SessionTimelineContentIdentity?,
    snapshot: SessionTimelineTableSnapshot,
    fontScale: CGFloat
  ) -> SessionTimelineTableHeightCacheSeed? {
    guard let identity,
      let entry = entries[identity],
      abs(entry.fontScale - fontScale) <= fontScaleTolerance
    else {
      return nil
    }

    let currentRowsByID = snapshot.rowSnapshotsByID
    let reusableHeights = entry.heightsByID.filter { id, height in
      guard height.isMeasured,
        let previousRow = entry.rowSnapshotsByID[id],
        let currentRow = currentRowsByID[id]
      else {
        return false
      }
      return previousRow == currentRow
    }
    guard !reusableHeights.isEmpty else {
      return nil
    }

    markAccess(for: identity)
    return SessionTimelineTableHeightCacheSeed(heightsByID: reusableHeights)
  }

  static func save(
    identity: SessionTimelineContentIdentity?,
    snapshot: SessionTimelineTableSnapshot,
    heightsByID: [String: CachedRowHeight],
    fontScale: CGFloat
  ) {
    guard let identity, !snapshot.rows.isEmpty else {
      return
    }
    let measuredHeights = heightsByID.filter { _, height in height.isMeasured }
    guard !measuredHeights.isEmpty else {
      return
    }

    let previousEntry = entries[identity]
    let canReuseStoredHeights =
      previousEntry.map {
        abs($0.fontScale - fontScale) <= fontScaleTolerance
      } ?? false
    var rowSnapshotsByID = canReuseStoredHeights ? previousEntry?.rowSnapshotsByID ?? [:] : [:]
    var storedHeights = canReuseStoredHeights ? previousEntry?.heightsByID ?? [:] : [:]
    for rowSnapshot in snapshot.rows {
      if rowSnapshotsByID[rowSnapshot.id] != rowSnapshot {
        storedHeights.removeValue(forKey: rowSnapshot.id)
      }
      rowSnapshotsByID[rowSnapshot.id] = rowSnapshot
    }
    for (id, height) in measuredHeights {
      storedHeights[id] = height
    }

    entries[identity] = Entry(
      rowSnapshotsByID: rowSnapshotsByID,
      heightsByID: storedHeights,
      fontScale: fontScale,
      accessIndex: nextAccessIndex()
    )
    trimIfNeeded()
  }

  static func removeAllForTests() {
    entries.removeAll()
    accessCounter = 0
  }

  private static func markAccess(for identity: SessionTimelineContentIdentity) {
    entries[identity]?.accessIndex = nextAccessIndex()
  }

  private static func nextAccessIndex() -> UInt64 {
    accessCounter &+= 1
    return accessCounter
  }

  private static func trimIfNeeded() {
    guard entries.count > maximumSessionCount else {
      return
    }
    let overflowCount = entries.count - maximumSessionCount
    let oldestKeys =
      entries
      .sorted { $0.value.accessIndex < $1.value.accessIndex }
      .prefix(overflowCount)
      .map(\.key)
    for key in oldestKeys {
      entries.removeValue(forKey: key)
    }
  }
}
