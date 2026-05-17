import Foundation
import SwiftData

extension HarnessMonitorStore {
  private func cancelSupersededPersistenceWork() {
    cancelPendingCacheWrite()
    sessionSnapshotHydrationTask?.cancel()
    sessionSnapshotHydrationTask = nil
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
    transcript: [TimelineEntry]? = nil,
    transcriptSource: HarnessMonitorSessionWindowTranscriptSource? = nil,
    timelineWindow: TimelineWindowResponse? = nil,
    markViewed: Bool = true
  ) async {
    guard let cacheService, persistenceError == nil else { return }
    cancelSupersededPersistenceWork()
    let result = await cacheService.cacheSessionDetail(
      detail,
      timeline: timeline,
      transcript: transcript,
      transcriptSource: transcriptSource,
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

  func pruneRemovedSessionFromCache(
    sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) async {
    guard let cacheService, persistenceError == nil else { return }
    cancelSupersededPersistenceWork()
    let result = await cacheService.cacheSessionList(sessions, projects: projects)
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
    cancelPendingGenericCacheWrite()
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

  func scheduleSessionDetailCacheWrite(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    transcript: [TimelineEntry]? = nil,
    transcriptSource: HarnessMonitorSessionWindowTranscriptSource? = nil,
    timelineWindow: TimelineWindowResponse? = nil,
    markViewed: Bool = true,
    preservesTimeline: Bool = false
  ) {
    guard cacheService != nil, persistenceError == nil else { return }
    pendingSessionDetailCacheWrites[detail.session.sessionId] = PendingSessionDetailCacheWrite(
      snapshot: SessionCacheService.CachedSessionSnapshot(
        detail: detail,
        timeline: timeline,
        timelineWindow: timelineWindow,
        transcript: transcript,
        transcriptSource: transcriptSource
      ),
      markViewed: markViewed,
      preservesTimeline: preservesTimeline
    )
    cancelPendingSessionDetailCacheWriteTask()
    pendingSessionDetailCacheWriteTaskToken &+= 1
    let taskToken = pendingSessionDetailCacheWriteTaskToken
    pendingSessionDetailCacheWriteTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.pendingSessionDetailCacheWriteTaskToken == taskToken {
          self.pendingSessionDetailCacheWriteTask = nil
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard
        !Task.isCancelled,
        self.pendingSessionDetailCacheWriteTaskToken == taskToken,
        let cacheService = self.cacheService,
        self.persistenceError == nil
      else {
        return
      }
      let pendingWrites = self.pendingSessionDetailCacheWrites
      self.pendingSessionDetailCacheWrites.removeAll()
      let writes = await self.sessionCacheWriteWorker.sortedPendingSessionDetailWrites(
        pendingWrites
      )
      for write in writes {
        let result = await cacheService.cacheSessionDetail(
          write.snapshot.detail,
          timeline: write.snapshot.timeline,
          transcript: write.snapshot.transcript,
          transcriptSource: write.snapshot.transcriptSource,
          timelineWindow: write.snapshot.timelineWindow,
          markViewed: write.markViewed,
          preservesTimeline: write.preservesTimeline
        )
        await self.applyPersistedCacheWriteResult(result)
      }
    }
  }

  func scheduleSelectedSessionCacheWrite(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    transcript: [TimelineEntry]? = nil,
    transcriptSource: HarnessMonitorSessionWindowTranscriptSource? = nil,
    timelineWindow: TimelineWindowResponse? = nil
  ) {
    // Selected-session transcript writes must preserve the provenance already
    // carried by in-memory ACP state; the final `.direct` fallback is only a
    // defensive bridge for older call sites that provide rows without source.
    let resolvedTranscript =
      transcript
      ?? (selectedSessionID == detail.session.sessionId ? selectedAcpTranscriptEntries : nil)
    let resolvedTranscriptSource =
      transcriptSource
      ?? (selectedSessionID == detail.session.sessionId ? selectedAcpTranscriptSource : nil)
      ?? (resolvedTranscript?.isEmpty == false ? .direct : nil)
    scheduleSessionDetailCacheWrite(
      detail,
      timeline: timeline,
      transcript: resolvedTranscript,
      transcriptSource: resolvedTranscriptSource,
      timelineWindow: timelineWindow
    )
  }

  func flushPendingCacheWrite() async {
    if let task = pendingSessionDetailCacheWriteTask {
      await task.value
    }
    if let task = pendingCacheWriteTask {
      await task.value
    }
  }

  func updatePersistedSessionMetadataAfterSave(insertedSessionCount: Int) {
    persistedSessionCount += insertedSessionCount
    lastPersistedSnapshotAt = .now
  }

  func cancelPendingCacheWrite() {
    cancelPendingGenericCacheWrite()
    cancelPendingSessionDetailCacheWriteTask()
    pendingSessionDetailCacheWrites.removeAll()
  }

  private func cancelPendingGenericCacheWrite() {
    pendingCacheWriteTask?.cancel()
    pendingCacheWriteTask = nil
    pendingCacheWriteTaskToken &+= 1
  }

  private func cancelPendingSessionDetailCacheWriteTask() {
    pendingSessionDetailCacheWriteTask?.cancel()
    pendingSessionDetailCacheWriteTask = nil
    pendingSessionDetailCacheWriteTaskToken &+= 1
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

actor SessionCacheWriteWorker {
  func sortedPendingSessionDetailWrites(
    _ writes: [String: PendingSessionDetailCacheWrite]
  ) -> [PendingSessionDetailCacheWrite] {
    writes
      .sorted { $0.key < $1.key }
      .map(\.value)
  }

  func waitForIdle() {}
}
