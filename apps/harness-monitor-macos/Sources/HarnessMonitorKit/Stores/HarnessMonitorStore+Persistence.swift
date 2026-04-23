import Foundation
import SwiftData

extension HarnessMonitorStore {
  private func awaitOutstandingDirectPersistenceConflicts() async {
    if let pendingCacheWriteTask {
      await pendingCacheWriteTask.value
    }
    if let sessionSnapshotHydrationTask {
      await sessionSnapshotHydrationTask.value
    }
  }

  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) async {
    guard let cacheService, persistenceError == nil else { return }

    let result = await cacheService.cacheSessionList(sessions, projects: projects)
    await applyPersistedCacheWriteResult(result)
  }

  func cacheSessionDetail(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse? = nil,
    markViewed: Bool = true
  ) async {
    guard let cacheService, persistenceError == nil else { return }
    await awaitOutstandingDirectPersistenceConflicts()
    let result = await cacheService.cacheSessionDetail(
      detail,
      timeline: timeline,
      timelineWindow: timelineWindow,
      markViewed: markViewed
    )
    await applyPersistedCacheWriteResult(result)
  }

  func cacheSessionDetails(
    _ entries: [SessionCacheService.CachedSessionSnapshot],
    markViewed: Bool = false
  ) async {
    guard let cacheService, persistenceError == nil else { return }
    guard !entries.isEmpty else { return }
    await awaitOutstandingDirectPersistenceConflicts()
    let result = await cacheService.cacheSessionDetails(entries, markViewed: markViewed)
    await applyPersistedCacheWriteResult(result)
  }

  func cacheSessionDetails(
    _ entries: [(detail: SessionDetail, timeline: [TimelineEntry])],
    markViewed: Bool = false
  ) async {
    await cacheSessionDetails(
      entries.map {
        SessionCacheService.CachedSessionSnapshot(
          detail: $0.detail,
          timeline: $0.timeline,
          timelineWindow: nil
        )
      },
      markViewed: markViewed
    )
  }

  func cacheSessionSummary(
    _ summary: SessionSummary,
    project: ProjectSummary?
  ) async {
    guard let cacheService, persistenceError == nil else { return }

    let result = await cacheService.cacheSessionSummary(summary, project: project)
    await applyPersistedCacheWriteResult(result)
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

  func scheduleCacheWrite(
    _ work: @escaping @MainActor (SessionCacheService) async -> SessionCacheService.WriteResult
  ) {
    guard let cacheService, persistenceError == nil else { return }
    cancelPendingCacheWrite()
    pendingCacheWriteTaskToken &+= 1
    let taskToken = pendingCacheWriteTaskToken
    pendingCacheWriteTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.pendingCacheWriteTaskToken == taskToken {
          self.pendingCacheWriteTask = nil
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, self.pendingCacheWriteTaskToken == taskToken else {
        return
      }
      let result = await work(cacheService)
      await self.applyPersistedCacheWriteResult(result)
    }
  }

  func updatePersistedSessionMetadataAfterSave(insertedSessionCount: Int) {
    persistedSessionCount += insertedSessionCount
    lastPersistedSnapshotAt = .now
  }

  func cancelPendingCacheWrite() {
    pendingCacheWriteTask?.cancel()
    pendingCacheWriteTask = nil
    pendingCacheWriteTaskToken &+= 1
  }

  private func applyPersistedCacheWriteResult(_ result: SessionCacheService.WriteResult) async {
    guard result.didPersist else {
      return
    }

    switch result.metadataUpdate {
    case .refresh:
      await refreshPersistedSessionMetadata()
    case .advance(let insertedSessionCount):
      updatePersistedSessionMetadataAfterSave(
        insertedSessionCount: insertedSessionCount
      )
    }
  }
}
