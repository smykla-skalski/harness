import Foundation
import SwiftData

extension HarnessMonitorStore {
  private func cancelSupersededPersistenceWork() {
    cancelPendingSessionDetailCacheWriteTask()
    cacheWriteSync.pendingSessionDetailCacheWrites.removeAll()
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

  func cacheTaskBoardSnapshot(
    items: [TaskBoardItem],
    orchestratorStatus: TaskBoardOrchestratorStatus?
  ) async {
    guard let cacheService, persistenceError == nil else { return }
    cancelPendingTaskBoardSnapshotCacheWriteTask()
    let result = await cacheService.cacheTaskBoardSnapshot(
      items: items,
      orchestratorStatus: orchestratorStatus
    )
    await applyPersistedCacheWriteResult(result)
  }

  func scheduleTaskBoardSnapshotCacheWrite(
    items: [TaskBoardItem],
    orchestratorStatus: TaskBoardOrchestratorStatus?
  ) {
    guard let cacheService, persistenceError == nil else { return }
    cancelPendingTaskBoardSnapshotCacheWriteTask()
    cacheWriteSync.taskBoardSnapshotCacheWriteToken &+= 1
    let taskToken = cacheWriteSync.taskBoardSnapshotCacheWriteToken
    cacheWriteSync.pendingTaskBoardSnapshotCacheWriteTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.cacheWriteSync.taskBoardSnapshotCacheWriteToken == taskToken {
          self.cacheWriteSync.pendingTaskBoardSnapshotCacheWriteTask = nil
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard
        !Task.isCancelled,
        self.cacheWriteSync.taskBoardSnapshotCacheWriteToken == taskToken
      else {
        return
      }
      let result = await cacheService.cacheTaskBoardSnapshot(
        items: items,
        orchestratorStatus: orchestratorStatus
      )
      await self.applyPersistedCacheWriteResult(result)
    }
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

  func loadCachedTaskBoardSnapshot() async -> SessionCacheService.CachedTaskBoardState? {
    guard let cacheService, persistenceError == nil else { return nil }
    return await cacheService.loadTaskBoardSnapshot()
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
    cacheWriteSync.pendingCacheWriteTaskToken &+= 1
    let taskToken = cacheWriteSync.pendingCacheWriteTaskToken
    cacheWriteSync.pendingCacheWriteTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.cacheWriteSync.pendingCacheWriteTaskToken == taskToken {
          self.cacheWriteSync.pendingCacheWriteTask = nil
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, self.cacheWriteSync.pendingCacheWriteTaskToken == taskToken else {
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
    cacheWriteSync.pendingSessionDetailCacheWrites[detail.session.sessionId] =
      PendingSessionDetailCacheWrite(
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
    cacheWriteSync.pendingSessionDetailCacheWriteTaskToken &+= 1
    let taskToken = cacheWriteSync.pendingSessionDetailCacheWriteTaskToken
    cacheWriteSync.pendingSessionDetailCacheWriteTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.cacheWriteSync.pendingSessionDetailCacheWriteTaskToken == taskToken {
          self.cacheWriteSync.pendingSessionDetailCacheWriteTask = nil
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard
        !Task.isCancelled,
        self.cacheWriteSync.pendingSessionDetailCacheWriteTaskToken == taskToken,
        let cacheService = self.cacheService,
        self.persistenceError == nil
      else {
        return
      }
      let pendingWrites = self.cacheWriteSync.pendingSessionDetailCacheWrites
      self.cacheWriteSync.pendingSessionDetailCacheWrites.removeAll()
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
    let sessionDetailTask = cacheWriteSync.pendingSessionDetailCacheWriteTask
    let genericTask = cacheWriteSync.pendingCacheWriteTask
    let taskBoardSnapshotTask = cacheWriteSync.pendingTaskBoardSnapshotCacheWriteTask

    await withTaskGroup(of: Void.self) { group in
      if let sessionDetailTask {
        group.addTask {
          await sessionDetailTask.value
        }
      }
      if let genericTask {
        group.addTask {
          await genericTask.value
        }
      }
      if let taskBoardSnapshotTask {
        group.addTask {
          await taskBoardSnapshotTask.value
        }
      }
    }
  }

  func updatePersistedSessionMetadataAfterSave(insertedSessionCount: Int) {
    persistedSessionCount += insertedSessionCount
    lastPersistedSnapshotAt = .now
  }

  func cancelPendingCacheWrite() {
    cancelPendingGenericCacheWrite()
    cancelPendingTaskBoardSnapshotCacheWriteTask()
    cancelPendingSessionDetailCacheWriteTask()
    cacheWriteSync.pendingSessionDetailCacheWrites.removeAll()
  }

  private func cancelPendingGenericCacheWrite() {
    cacheWriteSync.pendingCacheWriteTask?.cancel()
    cacheWriteSync.pendingCacheWriteTask = nil
    cacheWriteSync.pendingCacheWriteTaskToken &+= 1
  }

  private func cancelPendingTaskBoardSnapshotCacheWriteTask() {
    cacheWriteSync.pendingTaskBoardSnapshotCacheWriteTask?.cancel()
    cacheWriteSync.pendingTaskBoardSnapshotCacheWriteTask = nil
    cacheWriteSync.taskBoardSnapshotCacheWriteToken &+= 1
  }

  private func cancelPendingSessionDetailCacheWriteTask() {
    cacheWriteSync.pendingSessionDetailCacheWriteTask?.cancel()
    cacheWriteSync.pendingSessionDetailCacheWriteTask = nil
    cacheWriteSync.pendingSessionDetailCacheWriteTaskToken &+= 1
  }

  private func applyPersistedCacheWriteResult(_ result: SessionCacheService.WriteResult) async {
    guard result.didPersist else {
      return
    }

    switch result.metadataUpdate {
    case .none:
      break
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
