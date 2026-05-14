import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func recordReadCall(_ call: ReadCall) {
    lock.withLock {
      readCallCountsByKey[call.countKey, default: 0] += 1
    }
  }

  func readCallCount(_ call: ReadCall) -> Int {
    lock.withLock {
      readCallCountsByKey[call.countKey, default: 0]
    }
  }

  func recordSessionDetailScope(id: String, scope: String?) {
    lock.withLock {
      sessionDetailScopesByID[id, default: []].append(scope)
    }
  }

  func configureTimelineBatches(
    _ batches: [[TimelineEntry]],
    batchDelay: Duration? = nil,
    for sessionID: String
  ) {
    lock.withLock {
      timelineBatchesBySessionID[sessionID] = batches
      if let batchDelay {
        timelineBatchDelaysBySessionID[sessionID] = batchDelay
      } else {
        timelineBatchDelaysBySessionID.removeValue(forKey: sessionID)
      }
      timelinesBySessionID[sessionID] = batches.flatMap(\.self)
    }
  }

  func recordTimelineScope(sessionID: String, scope: TimelineScope) {
    lock.withLock {
      timelineScopesBySessionID[sessionID, default: []].append(scope)
    }
  }

  func recordTimelineWindowRequest(sessionID: String, request: TimelineWindowRequest) {
    lock.withLock {
      timelineWindowRequestsBySessionID[sessionID, default: []].append(request)
    }
  }

  func recordedTimelineWindowRequests(for sessionID: String) -> [TimelineWindowRequest] {
    lock.withLock {
      timelineWindowRequestsBySessionID[sessionID, default: []]
    }
  }

  func shutdown() async {
    lock.withLock {
      recordedShutdownCallCount += 1
    }
  }

  func dequeueAgentTuiSnapshot(
    from storage: inout [String: [AgentTuiSnapshot]],
    tuiID: String
  ) -> AgentTuiSnapshot? {
    guard var snapshots = storage[tuiID], let snapshot = snapshots.first else {
      return nil
    }

    snapshots.removeFirst()
    if snapshots.isEmpty {
      storage.removeValue(forKey: tuiID)
    } else {
      storage[tuiID] = snapshots
    }

    var tuis = agentTuisBySessionID[snapshot.sessionId] ?? []
    tuis.removeAll { $0.tuiId == snapshot.tuiId }
    tuis.insert(snapshot, at: 0)
    agentTuisBySessionID[snapshot.sessionId] = tuis
    return snapshot
  }
}

extension RecordingHarnessClient.ReadCall {
  var countKey: String {
    switch self {
    case .health:
      "health"
    case .transportLatency:
      "transport-latency"
    case .diagnostics:
      "diagnostics"
    case .projects:
      "projects"
    case .sessions:
      "sessions"
    case .sessionDetail(let sessionID):
      "session-detail:\(sessionID)"
    case .timeline(let sessionID):
      "timeline:\(sessionID)"
    case .timelineWindow(let sessionID):
      "timeline-window:\(sessionID)"
    case .acpTranscript(let sessionID):
      "acp-transcript:\(sessionID)"
    case .codexTranscript(let sessionID):
      "codex-transcript:\(sessionID)"
    case .taskBoardOrchestratorStatus:
      "task-board-orchestrator-status"
    case .taskBoardOrchestratorSettings:
      "task-board-orchestrator-settings"
    case .taskBoardPolicyPipeline:
      "task-board-policy-pipeline"
    case .taskBoardPolicyPipelineAudit:
      "task-board-policy-pipeline-audit"
    }
  }
}
