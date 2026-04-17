import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func configuredMutationDelay() -> Duration? { lock.withLock { mutationDelay } }
  func configuredProjects() -> [ProjectSummary]? { lock.withLock { projectSummariesStorage } }
  func configuredSessions() -> [SessionSummary]? { lock.withLock { sessionSummariesStorage } }

  func configuredSessionDetail(id: String) -> SessionDetail? {
    lock.withLock { sessionDetailsByID[id] }
  }

  func configuredDetailDelay(for sessionID: String) -> Duration? {
    lock.withLock { detailDelaysBySessionID[sessionID] }
  }

  func sessionDetailScopes(for sessionID: String) -> [String?] {
    lock.withLock { sessionDetailScopesByID[sessionID] ?? [] }
  }

  func configuredTimeline(for sessionID: String) -> [TimelineEntry]? {
    lock.withLock { timelinesBySessionID[sessionID] }
  }

  func timelineScopes(for sessionID: String) -> [TimelineScope] {
    lock.withLock { timelineScopesBySessionID[sessionID] ?? [] }
  }

  func configuredTimelineBatches(for sessionID: String) -> [[TimelineEntry]]? {
    lock.withLock { timelineBatchesBySessionID[sessionID] }
  }

  func configuredTimelineDelay(for sessionID: String) -> Duration? {
    lock.withLock { timelineDelaysBySessionID[sessionID] }
  }

  func configuredTimelineBatchDelay(for sessionID: String) -> Duration? {
    lock.withLock { timelineBatchDelaysBySessionID[sessionID] }
  }

  func configuredCodexRuns(for sessionID: String) -> [CodexRunSnapshot] {
    lock.withLock { codexRunsBySessionID[sessionID] ?? [] }
  }

  func configuredCodexRunsDelay(for sessionID: String) -> Duration? {
    lock.withLock { codexRunsDelaysBySessionID[sessionID] }
  }

  func configuredAgentTuis(for sessionID: String) -> [AgentTuiSnapshot] {
    lock.withLock { agentTuisBySessionID[sessionID] ?? [] }
  }

  func configuredAgentTuisDelay(for sessionID: String) -> Duration? {
    lock.withLock { agentTuisDelaysBySessionID[sessionID] }
  }

  func configuredCodexRun(id runID: String) -> CodexRunSnapshot? {
    lock.withLock {
      codexRunsBySessionID.values.flatMap(\.self).first { $0.runId == runID }
    }
  }

  func configuredAgentTui(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      agentTuisBySessionID.values.flatMap(\.self).first { $0.tuiId == tuiID }
    }
  }

  func dequeueConfiguredAgentTuiInputResponse(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &agentTuiInputResponsesByID,
        tuiID: tuiID
      )
    }
  }

  func dequeueConfiguredAgentTuiReadSnapshot(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &agentTuiReadSnapshotsByID,
        tuiID: tuiID
      )
    }
  }

  func recordCodexRun(_ run: CodexRunSnapshot) {
    lock.withLock {
      var runs = codexRunsBySessionID[run.sessionId] ?? []
      runs.removeAll { $0.runId == run.runId }
      runs.insert(run, at: 0)
      codexRunsBySessionID[run.sessionId] = runs
    }
  }

  func recordAgentTui(_ tui: AgentTuiSnapshot) {
    lock.withLock {
      var tuis = agentTuisBySessionID[tui.sessionId] ?? []
      tuis.removeAll { $0.tuiId == tui.tuiId }
      tuis.insert(tui, at: 0)
      agentTuisBySessionID[tui.sessionId] = tuis
    }
  }

  func configuredGlobalStreamEvents() -> [DaemonPushEvent] {
    lock.withLock { globalStreamEvents }
  }

  func configuredGlobalStreamError() -> (any Error)? {
    lock.withLock { globalStreamError }
  }

  func configuredSessionStreamEvents(for sessionID: String) -> [DaemonPushEvent] {
    lock.withLock { sessionStreamEventsBySessionID[sessionID] ?? [] }
  }

  func configuredSessionStreamError(for sessionID: String) -> (any Error)? {
    lock.withLock { sessionStreamErrorsBySessionID[sessionID] }
  }

  func shutdownCallCount() -> Int {
    lock.withLock { recordedShutdownCallCount }
  }
}
