import Foundation
import SwiftData

extension HarnessMonitorStore {
  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) async {
    guard let cacheService, persistenceError == nil else { return }

    let insertedCount = await cacheService.cacheSessionList(sessions, projects: projects)
    updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
  }

  func cacheSessionDetail(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    markViewed: Bool = true
  ) async {
    guard let cacheService, persistenceError == nil else { return }
    let insertedCount = await cacheService.cacheSessionDetail(
      detail,
      timeline: timeline,
      markViewed: markViewed
    )
    updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
  }

  func cacheSessionSummary(
    _ summary: SessionSummary,
    project: ProjectSummary?
  ) async {
    guard let cacheService, persistenceError == nil else { return }

    let isInsert = await cacheService.cacheSessionSummary(summary, project: project)
    if isInsert {
      updatePersistedSessionMetadataAfterSave(insertedSessionCount: 1)
    }
  }

  func loadCachedSessionList() async -> (
    sessions: [SessionSummary],
    projects: [ProjectSummary]
  )? {
    guard let cacheService, persistenceError == nil else { return nil }
    return await cacheService.loadSessionList()
  }

  func loadCachedSessionDetail(
    sessionID: String
  ) async -> SessionCacheService.CachedSessionSnapshot? {
    guard let cacheService, persistenceError == nil else { return nil }
    return await cacheService.loadSessionDetail(sessionID: sessionID)
  }

  func refreshPersistedSessionMetadata() async {
    guard let cacheService, persistenceError == nil else {
      persistedSessionCount = 0
      lastPersistedSnapshotAt = nil
      return
    }

    let metadata = await cacheService.sessionMetadata()
    persistedSessionCount = metadata.count
    lastPersistedSnapshotAt = metadata.lastCachedAt
  }

  func persistedSnapshotHydrationQueue(
    for summaries: [SessionSummary]
  ) async -> [SessionSummary] {
    guard let cacheService, persistenceError == nil else { return [] }
    guard !summaries.isEmpty else { return [] }
    return await cacheService.hydrationQueue(for: summaries)
  }

  func updatePersistedSessionMetadataAfterSave(insertedSessionCount: Int) {
    persistedSessionCount += insertedSessionCount
    lastPersistedSnapshotAt = .now
  }
}
