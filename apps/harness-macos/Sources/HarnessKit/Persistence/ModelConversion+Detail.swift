import Foundation
import SwiftData

// MARK: - SessionSignalRecord <-> CachedSignalRecord

extension CachedSignalRecord {
  public func toSessionSignalRecord() -> SessionSignalRecord {
    let signal = (try? JSONDecoder().decode(Signal.self, from: signalData))
      ?? Signal(
        signalId: signalId,
        version: 0,
        createdAt: "",
        expiresAt: "",
        sourceAgent: agentId,
        command: "",
        priority: .normal,
        payload: SignalPayload(
          message: "",
          actionHint: nil,
          relatedFiles: [],
          metadata: .null
        ),
        delivery: DeliveryConfig(
          maxRetries: 0,
          retryCount: 0,
          idempotencyKey: nil
        )
      )

    let acknowledgment: SignalAck? =
      if let data = acknowledgmentData {
        try? JSONDecoder().decode(SignalAck.self, from: data)
      } else {
        nil
      }

    return SessionSignalRecord(
      runtime: runtime,
      agentId: agentId,
      sessionId: sessionId,
      status: SessionSignalStatus(rawValue: statusRaw) ?? .pending,
      signal: signal,
      acknowledgment: acknowledgment
    )
  }

  public func update(from record: SessionSignalRecord) {
    runtime = record.runtime
    agentId = record.agentId
    sessionId = record.sessionId
    statusRaw = record.status.rawValue
    signalData = (try? JSONEncoder().encode(record.signal)) ?? Data()
    acknowledgmentData = record.acknowledgment.flatMap {
      try? JSONEncoder().encode($0)
    }
  }
}

extension SessionSignalRecord {
  public func toCachedSignalRecord() -> CachedSignalRecord {
    CachedSignalRecord(
      signalId: signal.signalId,
      runtime: runtime,
      agentId: agentId,
      sessionId: sessionId,
      statusRaw: status.rawValue,
      signalData: (try? JSONEncoder().encode(signal)) ?? Data(),
      acknowledgmentData: acknowledgment.flatMap {
        try? JSONEncoder().encode($0)
      }
    )
  }
}

// MARK: - TimelineEntry <-> CachedTimelineEntry

extension CachedTimelineEntry {
  public func toTimelineEntry() -> TimelineEntry {
    let payload = (try? JSONDecoder().decode(
      JSONValue.self,
      from: payloadData
    )) ?? .null

    return TimelineEntry(
      entryId: entryId,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: sessionId,
      agentId: agentId,
      taskId: taskId,
      summary: summary,
      payload: payload
    )
  }

  public func update(from entry: TimelineEntry) {
    recordedAt = entry.recordedAt
    kind = entry.kind
    sessionId = entry.sessionId
    agentId = entry.agentId
    taskId = entry.taskId
    summary = entry.summary
    payloadData = (try? JSONEncoder().encode(entry.payload)) ?? Data()
  }
}

extension TimelineEntry {
  public func toCachedTimelineEntry() -> CachedTimelineEntry {
    CachedTimelineEntry(
      entryId: entryId,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: sessionId,
      agentId: agentId,
      taskId: taskId,
      summary: summary,
      payloadData: (try? JSONEncoder().encode(payload)) ?? Data()
    )
  }
}

// MARK: - ObserverSummary <-> CachedObserver

struct ObserverDetailBlob: Codable {
  var openIssues: [ObserverIssueSummary]?
  var mutedCodes: [String]?
  var activeWorkers: [ObserverWorkerSummary]?
  var cycleHistory: [ObserverCycleSummary]?
  var agentSessions: [ObserverAgentSessionSummary]?
}

extension CachedObserver {
  public func toObserverSummary() -> ObserverSummary {
    let detail = (try? JSONDecoder().decode(
      ObserverDetailBlob.self,
      from: detailData
    )) ?? ObserverDetailBlob()

    return ObserverSummary(
      observeId: observeId,
      lastScanTime: lastScanTime,
      openIssueCount: openIssueCount,
      resolvedIssueCount: resolvedIssueCount,
      mutedCodeCount: mutedCodeCount,
      activeWorkerCount: activeWorkerCount,
      openIssues: detail.openIssues,
      mutedCodes: detail.mutedCodes,
      activeWorkers: detail.activeWorkers,
      cycleHistory: detail.cycleHistory,
      agentSessions: detail.agentSessions
    )
  }

  public func update(from summary: ObserverSummary) {
    observeId = summary.observeId
    lastScanTime = summary.lastScanTime
    openIssueCount = summary.openIssueCount
    resolvedIssueCount = summary.resolvedIssueCount
    mutedCodeCount = summary.mutedCodeCount
    activeWorkerCount = summary.activeWorkerCount
    let blob = ObserverDetailBlob(
      openIssues: summary.openIssues,
      mutedCodes: summary.mutedCodes,
      activeWorkers: summary.activeWorkers,
      cycleHistory: summary.cycleHistory,
      agentSessions: summary.agentSessions
    )
    detailData = (try? JSONEncoder().encode(blob)) ?? Data()
  }
}

extension ObserverSummary {
  public func toCachedObserver() -> CachedObserver {
    let blob = ObserverDetailBlob(
      openIssues: openIssues,
      mutedCodes: mutedCodes,
      activeWorkers: activeWorkers,
      cycleHistory: cycleHistory,
      agentSessions: agentSessions
    )
    return CachedObserver(
      observeId: observeId,
      lastScanTime: lastScanTime,
      openIssueCount: openIssueCount,
      resolvedIssueCount: resolvedIssueCount,
      mutedCodeCount: mutedCodeCount,
      activeWorkerCount: activeWorkerCount,
      detailData: (try? JSONEncoder().encode(blob)) ?? Data()
    )
  }
}

// MARK: - AgentToolActivitySummary <-> CachedAgentActivity

extension CachedAgentActivity {
  public func toAgentToolActivitySummary() -> AgentToolActivitySummary {
    let recentTools = (try? JSONDecoder().decode(
      [String].self,
      from: recentToolsData
    )) ?? []

    return AgentToolActivitySummary(
      agentId: agentId,
      runtime: runtime,
      toolInvocationCount: toolInvocationCount,
      toolResultCount: toolResultCount,
      toolErrorCount: toolErrorCount,
      latestToolName: latestToolName,
      latestEventAt: latestEventAt,
      recentTools: recentTools
    )
  }

  public func update(from activity: AgentToolActivitySummary) {
    runtime = activity.runtime
    toolInvocationCount = activity.toolInvocationCount
    toolResultCount = activity.toolResultCount
    toolErrorCount = activity.toolErrorCount
    latestToolName = activity.latestToolName
    latestEventAt = activity.latestEventAt
    recentToolsData = (try? JSONEncoder().encode(
      activity.recentTools
    )) ?? Data()
  }
}

extension AgentToolActivitySummary {
  public func toCachedAgentActivity() -> CachedAgentActivity {
    CachedAgentActivity(
      agentId: agentId,
      runtime: runtime,
      toolInvocationCount: toolInvocationCount,
      toolResultCount: toolResultCount,
      toolErrorCount: toolErrorCount,
      latestToolName: latestToolName,
      latestEventAt: latestEventAt,
      recentToolsData: (try? JSONEncoder().encode(recentTools)) ?? Data()
    )
  }
}
