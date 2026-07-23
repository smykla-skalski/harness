import Foundation

public enum HarnessMonitorPushEventError: Error, LocalizedError, Equatable {
  case missingSessionID(String)

  public var errorDescription: String? {
    switch self {
    case .missingSessionID(let event):
      "Missing session ID for daemon push event '\(event)'"
    }
  }
}

public enum AcpPermissionBatchRemovalReason: String, Equatable, Sendable {
  case resolved
  case shutdown
  case timeout
}

public struct AcpPermissionBatchRemovedPayload: Equatable, Sendable {
  public let batch: AcpPermissionBatch
  public let reason: AcpPermissionBatchRemovalReason

  public init(
    batch: AcpPermissionBatch,
    reason: AcpPermissionBatchRemovalReason
  ) {
    self.batch = batch
    self.reason = reason
  }
}

public struct GitHubDataChangedPayload: Codable, Equatable, Sendable {
  public let revision: UInt64
  public let operation: String

  public init(revision: UInt64, operation: String) {
    self.revision = revision
    self.operation = operation
  }
}

public struct TaskBoardUpdatedPayload: Codable, Equatable, Sendable {
  public let revision: UInt64
  public let scopes: [String]
  public let automation: TaskBoardAutomationSnapshot?

  public init(
    revision: UInt64,
    scopes: [String],
    automation: TaskBoardAutomationSnapshot? = nil
  ) {
    self.revision = revision
    self.scopes = scopes
    self.automation = automation
  }
}

public struct DaemonPushEvent: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    case ready
    case sessionsUpdated(SessionsUpdatedPayload)
    case sessionsUpdatedDelta(SessionsUpdatedDeltaPayload)
    case sessionUpdated(SessionUpdatedPayload)
    case sessionExtensions(SessionExtensionsPayload)
    case logLevelChanged(LogLevelResponse)
    case codexRunUpdated(CodexRunSnapshot)
    case codexApprovalRequested(CodexApprovalRequestedPayload)
    case agentTuiUpdated(AgentTuiSnapshot)
    case acpAgentUpdated(AcpAgentSnapshot)
    case acpInspect(AcpAgentInspectResponse)
    case acpAgentsReconciled(AcpAgentsReconciledPayload)
    case acpEvents(AcpEventBatchPayload)
    case acpProcessIncident(AcpProcessIncidentPayload)
    case acpBridgeResyncIncident(AcpBridgeResyncIncidentPayload)
    case acpPermissionBatch(AcpPermissionBatch)
    case acpPermissionBatchRemoved(AcpPermissionBatchRemovedPayload)
    case githubDataChanged(GitHubDataChangedPayload)
    case taskBoardUpdated(TaskBoardUpdatedPayload)
    case reviewsLocalCloneProgress(ReviewLocalCloneProgress)
    case auditEvent(HarnessMonitorAuditEvent)
    case unknown(eventName: String, payload: JSONValue)
  }

  public let recordedAt: String
  public let sessionId: String?
  public let kind: Kind
  private let stableID: UUID

  public var id: UUID { stableID }

  public init(
    recordedAt: String,
    sessionId: String?,
    kind: Kind,
    stableID: UUID = UUID()
  ) {
    self.recordedAt = recordedAt
    self.sessionId = sessionId
    self.kind = kind
    self.stableID = stableID
  }

  public init(streamEvent: StreamEvent) throws {
    self = try Self.make(from: streamEvent)
  }

  private static func make(from streamEvent: StreamEvent) throws -> Self {
    let at = streamEvent.recordedAt
    switch streamEvent.event {
    case "ready":
      return Self(recordedAt: at, sessionId: streamEvent.sessionId, kind: .ready)
    case "sessions_updated":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .sessionsUpdated(
          try SessionsUpdatedPayload(
            wire: streamEvent.decodePayloadWire(as: SessionsUpdatedPayloadWire.self)))
      )
    case "sessions_updated_delta":
      return Self(
        recordedAt: at,
        sessionId: streamEvent.sessionId,
        kind: .sessionsUpdatedDelta(
          try SessionsUpdatedDeltaPayload(
            wire: streamEvent.decodePayloadWire(as: SessionsUpdatedDeltaPayloadWire.self)
          )
        )
      )
    case "log_level_changed":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .logLevelChanged(
          try LogLevelResponse(wire: streamEvent.decodePayloadWire(as: LogLevelResponseWire.self)))
      )
    case "acp_bridge_resync_incident":
      return Self(
        recordedAt: at,
        sessionId: streamEvent.sessionId,
        kind: .acpBridgeResyncIncident(
          try AcpBridgeResyncIncidentPayload(
            wire: streamEvent.decodePayloadWire(as: AcpBridgeResyncIncidentPayloadWire.self)
          )
        )
      )
    case "reviews_local_clone_progress":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .reviewsLocalCloneProgress(
          ReviewLocalCloneProgress(
            wire: try streamEvent.decodePayloadWire(as: LocalCloneProgressEventPayloadWire.self)
          )
        )
      )
    case "github_data_changed":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .githubDataChanged(
          try streamEvent.decodePayloadWire(as: GitHubDataChangedPayload.self)
        )
      )
    case "task_board_updated":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .taskBoardUpdated(
          try streamEvent.decodePayloadWire(as: TaskBoardUpdatedPayload.self)
        )
      )
    case "audit_event":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .auditEvent(
          try HarnessMonitorAuditEvent(
            wire: streamEvent.decodePayloadWire(as: HarnessMonitorAuditEventWire.self)))
      )
    default:
      return try Self.makeSessionScopedEvent(from: streamEvent)
    }
  }

  private static func makeSessionScopedEvent(from streamEvent: StreamEvent) throws -> Self {
    guard let sessionId = streamEvent.sessionId else {
      throw HarnessMonitorPushEventError.missingSessionID(streamEvent.event)
    }
    if let acpEvent = try makeAcpSessionScopedEvent(from: streamEvent, sessionId: sessionId) {
      return acpEvent
    }

    let at = streamEvent.recordedAt
    switch streamEvent.event {
    case "session_updated":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .sessionUpdated(
          try SessionUpdatedPayload(
            wire: streamEvent.decodePayloadWire(as: SessionUpdatedPayloadWire.self)))
      )
    case "session_extensions":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .sessionExtensions(
          try SessionExtensionsPayload(
            wire: streamEvent.decodePayloadWire(as: SessionExtensionsPayloadWire.self)
          )
        )
      )
    case "codex_run_updated":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .codexRunUpdated(
          try CodexRunSnapshot(wire: streamEvent.decodePayloadWire(as: CodexRunSnapshotWire.self)))
      )
    case "codex_approval_requested":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .codexApprovalRequested(
          try CodexApprovalRequestedPayload(
            wire: streamEvent.decodePayloadWire(as: CodexApprovalRequestedPayloadWire.self)
          )
        )
      )
    case "agent_tui_started", "agent_tui_updated", "agent_tui_stopped", "agent_tui_failed":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .agentTuiUpdated(
          try AgentTuiSnapshot(wire: streamEvent.decodePayloadWire(as: AgentTuiSnapshotWire.self)))
      )
    default:
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .unknown(eventName: streamEvent.event, payload: streamEvent.payload)
      )
    }
  }

  private static func makeAcpSessionScopedEvent(
    from streamEvent: StreamEvent,
    sessionId: String
  ) throws -> Self? {
    let at = streamEvent.recordedAt
    switch streamEvent.event {
    case "acp_inspect":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .acpInspect(
          AcpAgentInspectResponse(
            wire: try streamEvent.decodePayloadWire(as: AcpInspectPushPayload.self).inspect
          )
        )
      )
    case "acp_agents_reconciled":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .acpAgentsReconciled(
          try AcpAgentsReconciledPayload(
            wire: streamEvent.decodePayloadWire(as: AcpAgentsReconciledPayloadWire.self)
          )
        )
      )
    case "acp_agent_started", "acp_agent_updated", "acp_agent_stopped", "acp_agent_failed",
      "acp_permission_batch_resolved":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .acpAgentUpdated(
          try AcpAgentSnapshot(wire: streamEvent.decodePayloadWire(as: AcpAgentSnapshotWire.self)))
      )
    case "acp_events":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .acpEvents(
          try AcpEventBatchPayload(
            wire: streamEvent.decodePayloadWire(as: AcpEventBatchPayloadWire.self)))
      )
    case "acp_process_incident":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .acpProcessIncident(
          try AcpProcessIncidentPayload(
            wire: streamEvent.decodePayloadWire(as: AcpProcessIncidentPayloadWire.self)
          )
        )
      )
    case "acp_permission_requested":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .acpPermissionBatch(
          try AcpPermissionBatch(
            wire: streamEvent.decodePayloadWire(as: AcpPermissionBatchWire.self)))
      )
    case "acp_permission_resolved":
      return try makeAcpPermissionBatchRemoved(
        from: streamEvent, sessionId: sessionId, reason: .resolved
      )
    case "acp_permission_shutdown":
      return try makeAcpPermissionBatchRemoved(
        from: streamEvent, sessionId: sessionId, reason: .shutdown
      )
    case "acp_permission_timeout":
      return try makeAcpPermissionBatchRemoved(
        from: streamEvent, sessionId: sessionId, reason: .timeout
      )
    default:
      return nil
    }
  }

  private static func makeAcpPermissionBatchRemoved(
    from streamEvent: StreamEvent,
    sessionId: String,
    reason: AcpPermissionBatchRemovalReason
  ) throws -> Self {
    Self(
      recordedAt: streamEvent.recordedAt,
      sessionId: sessionId,
      kind: .acpPermissionBatchRemoved(
        AcpPermissionBatchRemovedPayload(
          batch: try AcpPermissionBatch(
            wire: streamEvent.decodePayloadWire(as: AcpPermissionBatchWire.self)),
          reason: reason
        )
      )
    )
  }

}

/// Authoritative ACP agent snapshot set for one session.
///
/// UI-0 contract: this payload already exists in-tree and is the authoritative replacement source
/// for selected-session ACP state. Future Decisions-window integration may change presentation,
/// but it must continue to treat reconcile pushes as snapshot authority rather than a second queue
/// alongside incremental permission events.
public struct AcpAgentsReconciledPayload: Codable, Equatable, Sendable {
  public let sessionId: String
  public let agents: [AcpAgentSnapshot]
  public let inspect: AcpAgentInspectResponse?

  public init(
    sessionId: String,
    agents: [AcpAgentSnapshot],
    inspect: AcpAgentInspectResponse? = nil
  ) {
    self.sessionId = sessionId
    self.agents = agents
    self.inspect = inspect
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case agents
    case inspect
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    agents = try container.decode([AcpAgentSnapshot].self, forKey: .agents)
    inspect = try container.decodeIfPresent(AcpAgentInspectResponse.self, forKey: .inspect)
  }
}

private struct AcpInspectPushPayload: Codable, Equatable, Sendable {
  let inspect: AcpAgentInspectResponseWire
}

public struct AcpProcessIncidentPayload: Codable, Equatable, Sendable {
  public let kind: String
  public let reasonKind: String
  public let processKey: String
  public let pid: UInt32
  public let pgid: Int32
  public let exitCode: Int32?
  public let exitSignal: Int32?
  public let stderrTail: String?
  public let affectedLogicalSessionIds: [String]
}

public struct AcpBridgeResyncIncidentPayload: Codable, Equatable, Sendable {
  public let kind: String
  public let bridgeEpoch: String
  public let continuity: UInt64
  public let nextSeq: UInt64
  public let truncated: Bool
  public let affectedLogicalSessionIds: [String]
}
