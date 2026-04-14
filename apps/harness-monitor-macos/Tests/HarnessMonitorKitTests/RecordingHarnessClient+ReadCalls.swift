import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func recordReadCall(_ call: ReadCall) {
    lock.withLock {
      switch call {
      case .health:
        recordedHealthCallCount += 1
      case .transportLatency:
        recordedTransportLatencyCallCount += 1
      case .diagnostics:
        recordedDiagnosticsCallCount += 1
      case .projects:
        recordedProjectsCallCount += 1
      case .sessions:
        recordedSessionsCallCount += 1
      case .sessionDetail(let sessionID):
        sessionDetailCallCountsBySessionID[sessionID, default: 0] += 1
      case .timeline(let sessionID):
        timelineCallCountsBySessionID[sessionID, default: 0] += 1
      case .timelineWindow(let sessionID):
        timelineWindowCallCountsBySessionID[sessionID, default: 0] += 1
      }
    }
  }

  func readCallCount(_ call: ReadCall) -> Int {
    lock.withLock {
      switch call {
      case .health:
        recordedHealthCallCount
      case .transportLatency:
        recordedTransportLatencyCallCount
      case .diagnostics:
        recordedDiagnosticsCallCount
      case .projects:
        recordedProjectsCallCount
      case .sessions:
        recordedSessionsCallCount
      case .sessionDetail(let sessionID):
        sessionDetailCallCountsBySessionID[sessionID, default: 0]
      case .timeline(let sessionID):
        timelineCallCountsBySessionID[sessionID, default: 0]
      case .timelineWindow(let sessionID):
        timelineWindowCallCountsBySessionID[sessionID, default: 0]
      }
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
