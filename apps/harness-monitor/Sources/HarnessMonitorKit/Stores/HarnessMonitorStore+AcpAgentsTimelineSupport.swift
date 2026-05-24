import Foundation

extension HarnessMonitorStore {
  func applyAcpProcessIncident(
    _ payload: AcpProcessIncidentPayload,
    recordedAt: String,
    sessionID: String?
  ) {
    guard let resolvedSessionID = sessionID ?? payload.affectedLogicalSessionIds.first,
      resolvedSessionID == selectedSessionID
    else {
      return
    }
    noteAcpSessionActivity(sessionID: resolvedSessionID)
    let entry = TimelineEntry(
      entryId: "acp-incident-\(payload.processKey)-\(recordedAt)-\(payload.kind)",
      recordedAt: recordedAt,
      kind: "acp_process_incident",
      sessionId: resolvedSessionID,
      agentId: nil,
      taskId: nil,
      summary: "ACP process incident: \(payload.kind)",
      payload: .object([
        "runtime": .string("acp"),
        "incident": .object([
          "kind": .string(payload.kind),
          "reason_kind": .string(payload.reasonKind),
          "process_key": .string(payload.processKey),
          "pid": .number(Double(payload.pid)),
          "pgid": .number(Double(payload.pgid)),
          "exit_code": payload.exitCode.map { .number(Double($0)) } ?? .null,
          "exit_signal": payload.exitSignal.map { .number(Double($0)) } ?? .null,
          "stderr_tail": payload.stderrTail.map(JSONValue.string) ?? .null,
          "affected_logical_session_ids": .array(
            payload.affectedLogicalSessionIds.map(JSONValue.string)
          ),
        ]),
      ])
    )
    applyAcpTimelineEntries([entry])
  }

  func applyAcpBridgeResyncIncident(
    _ payload: AcpBridgeResyncIncidentPayload,
    recordedAt: String,
    sessionID: String?
  ) {
    guard let resolvedSessionID = sessionID ?? payload.affectedLogicalSessionIds.first,
      resolvedSessionID == selectedSessionID
    else {
      return
    }
    noteAcpSessionActivity(sessionID: resolvedSessionID)
    let resyncEntryID =
      "acp-resync-\(payload.bridgeEpoch)-\(payload.continuity)-\(payload.nextSeq)-\(resolvedSessionID)"
    let entry = TimelineEntry(
      entryId: resyncEntryID,
      recordedAt: recordedAt,
      kind: "acp_bridge_resync_incident",
      sessionId: resolvedSessionID,
      agentId: nil,
      taskId: nil,
      summary: "ACP bridge resync incident: \(payload.kind)",
      payload: .object([
        "runtime": .string("acp"),
        "incident": .object([
          "kind": .string(payload.kind),
          "bridge_epoch": .string(payload.bridgeEpoch),
          "continuity": .number(Double(payload.continuity)),
          "next_seq": .number(Double(payload.nextSeq)),
          "truncated": .bool(payload.truncated),
          "affected_logical_session_ids": .array(
            payload.affectedLogicalSessionIds.map(JSONValue.string)
          ),
        ]),
      ])
    )
    applyAcpTimelineEntries([entry])
  }

  func noteAcpSessionActivity(
    sessionID: String,
    at observedAt: Date = .now
  ) {
    acpPermissionLastSignalAtBySessionID[sessionID] = observedAt
  }
}
