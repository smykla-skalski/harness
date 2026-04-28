import Foundation
import SwiftData

// MARK: - SessionSignalRecord <-> CachedSignalRecord

extension CachedSignalRecord {
  func toSessionSignalRecord() -> SessionSignalRecord {
    let signal =
      (try? Codecs.decoder.decode(Signal.self, from: signalData))
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
        try? Codecs.decoder.decode(SignalAck.self, from: data)
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

  func update(from record: SessionSignalRecord) {
    runtime = record.runtime
    agentId = record.agentId
    sessionId = record.sessionId
    statusRaw = record.status.rawValue
    signalData = (try? Codecs.encoder.encode(record.signal)) ?? Data()
    acknowledgmentData = record.acknowledgment.flatMap {
      try? Codecs.encoder.encode($0)
    }
  }
}

extension SessionSignalRecord {
  func toCachedSignalRecord() -> CachedSignalRecord {
    CachedSignalRecord(
      signalId: signal.signalId,
      runtime: runtime,
      agentId: agentId,
      sessionId: sessionId,
      statusRaw: status.rawValue,
      signalData: (try? Codecs.encoder.encode(signal)) ?? Data(),
      acknowledgmentData: acknowledgment.flatMap {
        try? Codecs.encoder.encode($0)
      }
    )
  }
}

// MARK: - TimelineEntry <-> CachedTimelineEntry

extension CachedTimelineEntry {
  func toTimelineEntry() -> TimelineEntry {
    let payload =
      (try? Codecs.decoder.decode(
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

  func update(from entry: TimelineEntry) {
    recordedAt = entry.recordedAt
    kind = entry.kind
    sessionId = entry.sessionId
    agentId = entry.agentId
    taskId = entry.taskId
    summary = entry.summary
    payloadData = (try? Codecs.encoder.encode(entry.payload)) ?? Data()
  }
}

extension TimelineEntry {
  func toCachedTimelineEntry() -> CachedTimelineEntry {
    CachedTimelineEntry(
      entryId: entryId,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: sessionId,
      agentId: agentId,
      taskId: taskId,
      summary: summary,
      payloadData: (try? Codecs.encoder.encode(payload)) ?? Data()
    )
  }
}

// MARK: - ObserverSummary <-> CachedObserver

struct ObserverDetailBlob: Codable {
  var openIssues: [ObserverIssueSummary]?
  var mutedCodes: [String]?
  var activeWorkers: [ObserverWorkerSummary]?
  var agentSessions: [ObserverAgentSessionSummary]?
}

extension CachedObserver {
  func toObserverSummary() -> ObserverSummary {
    let detail =
      (try? Codecs.decoder.decode(
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
      agentSessions: detail.agentSessions
    )
  }

  func update(from summary: ObserverSummary) {
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
      agentSessions: summary.agentSessions
    )
    detailData = (try? Codecs.encoder.encode(blob)) ?? Data()
  }
}

extension ObserverSummary {
  func toCachedObserver() -> CachedObserver {
    let blob = ObserverDetailBlob(
      openIssues: openIssues,
      mutedCodes: mutedCodes,
      activeWorkers: activeWorkers,
      agentSessions: agentSessions
    )
    return CachedObserver(
      observeId: observeId,
      lastScanTime: lastScanTime,
      openIssueCount: openIssueCount,
      resolvedIssueCount: resolvedIssueCount,
      mutedCodeCount: mutedCodeCount,
      activeWorkerCount: activeWorkerCount,
      detailData: (try? Codecs.encoder.encode(blob)) ?? Data()
    )
  }
}

// MARK: - AgentToolActivitySummary <-> CachedAgentActivity

private struct CachedAgentActivityPayload: Codable {
  let recentTools: [String]
  let pendingUserPrompt: AgentPendingUserPrompt?
}

private func decodeCachedAgentActivityPayload(from data: Data) -> CachedAgentActivityPayload {
  if let payload = try? Codecs.decoder.decode(CachedAgentActivityPayload.self, from: data) {
    return payload
  }

  let recentTools = (try? Codecs.decoder.decode([String].self, from: data)) ?? []
  return CachedAgentActivityPayload(recentTools: recentTools, pendingUserPrompt: nil)
}

private func encodeCachedAgentActivityPayload(
  recentTools: [String],
  pendingUserPrompt: AgentPendingUserPrompt?
) -> Data {
  let payload = CachedAgentActivityPayload(
    recentTools: recentTools,
    pendingUserPrompt: pendingUserPrompt
  )
  return (try? Codecs.encoder.encode(payload)) ?? Data()
}

extension CachedAgentActivity {
  func toAgentToolActivitySummary() -> AgentToolActivitySummary {
    let payload = decodeCachedAgentActivityPayload(from: recentToolsData)

    return AgentToolActivitySummary(
      agentId: agentId,
      runtime: runtime,
      toolInvocationCount: toolInvocationCount,
      toolResultCount: toolResultCount,
      toolErrorCount: toolErrorCount,
      latestToolName: latestToolName,
      latestEventAt: latestEventAt,
      recentTools: payload.recentTools,
      pendingUserPrompt: payload.pendingUserPrompt
    )
  }

  func update(from activity: AgentToolActivitySummary) {
    runtime = activity.runtime
    toolInvocationCount = activity.toolInvocationCount
    toolResultCount = activity.toolResultCount
    toolErrorCount = activity.toolErrorCount
    latestToolName = activity.latestToolName
    latestEventAt = activity.latestEventAt
    recentToolsData = encodeCachedAgentActivityPayload(
      recentTools: activity.recentTools,
      pendingUserPrompt: activity.pendingUserPrompt
    )
  }
}

extension AgentToolActivitySummary {
  func toCachedAgentActivity() -> CachedAgentActivity {
    CachedAgentActivity(
      agentId: agentId,
      runtime: runtime,
      toolInvocationCount: toolInvocationCount,
      toolResultCount: toolResultCount,
      toolErrorCount: toolErrorCount,
      latestToolName: latestToolName,
      latestEventAt: latestEventAt,
      recentToolsData: encodeCachedAgentActivityPayload(
        recentTools: recentTools,
        pendingUserPrompt: pendingUserPrompt
      )
    )
  }
}
