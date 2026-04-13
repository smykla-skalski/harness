import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func recordReadCall(_ call: ReadCall) {
    lock.withLock {
      switch call {
      case .health:
        _healthCallCount += 1
      case .transportLatency:
        _transportLatencyCallCount += 1
      case .diagnostics:
        _diagnosticsCallCount += 1
      case .projects:
        _projectsCallCount += 1
      case .sessions:
        _sessionsCallCount += 1
      case .sessionDetail(let sessionID):
        _sessionDetailCallCounts[sessionID, default: 0] += 1
      case .timeline(let sessionID):
        _timelineCallCounts[sessionID, default: 0] += 1
      }
    }
  }

  func readCallCount(_ call: ReadCall) -> Int {
    lock.withLock {
      switch call {
      case .health:
        _healthCallCount
      case .transportLatency:
        _transportLatencyCallCount
      case .diagnostics:
        _diagnosticsCallCount
      case .projects:
        _projectsCallCount
      case .sessions:
        _sessionsCallCount
      case .sessionDetail(let sessionID):
        _sessionDetailCallCounts[sessionID, default: 0]
      case .timeline(let sessionID):
        _timelineCallCounts[sessionID, default: 0]
      }
    }
  }

  func recordSessionDetailScope(id: String, scope: String?) {
    lock.withLock {
      _sessionDetailScopesByID[id, default: []].append(scope)
    }
  }

  func configureTimelineBatches(
    _ batches: [[TimelineEntry]],
    batchDelay: Duration? = nil,
    for sessionID: String
  ) {
    lock.withLock {
      _timelineBatchesBySessionID[sessionID] = batches
      if let batchDelay {
        _timelineBatchDelaysBySessionID[sessionID] = batchDelay
      } else {
        _timelineBatchDelaysBySessionID.removeValue(forKey: sessionID)
      }
      _timelinesBySessionID[sessionID] = batches.flatMap(\.self)
    }
  }

  func recordTimelineScope(sessionID: String, scope: TimelineScope) {
    lock.withLock {
      _timelineScopesBySessionID[sessionID, default: []].append(scope)
    }
  }

  func shutdown() async {
    lock.withLock {
      _shutdownCallCount += 1
    }
  }

  private func dequeueAgentTuiSnapshot(
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

    var tuis = _agentTuisBySessionID[snapshot.sessionId] ?? []
    tuis.removeAll { $0.tuiId == snapshot.tuiId }
    tuis.insert(snapshot, at: 0)
    _agentTuisBySessionID[snapshot.sessionId] = tuis
    return snapshot
  }
}
