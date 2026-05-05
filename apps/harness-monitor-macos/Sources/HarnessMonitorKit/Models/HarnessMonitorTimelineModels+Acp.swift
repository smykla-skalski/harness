import Foundation

struct AcpToolCallTimelineMetadata: Equatable, Sendable {
  let acpAgentId: String?
  let agentId: String?
  let displayName: String?
  let capabilityTags: [String]
}

private struct AcpTimelineIdentity: Sendable {
  let acpAgentId: String
  let agentId: String
  let summaryActor: String
}

extension AcpEventBatchPayload {
  /// Converts ACP transcript events into timeline rows while preserving the server-side ordering
  /// guarantees. `drop-oldest` policy belongs after decode and before store mutation so the wire contract
  /// stays stable across UI-only refactors.
  public func timelineEntries(
    fallbackRecordedAt: String
  ) -> [TimelineEntry] {
    timelineEntries(
      fallbackRecordedAt: fallbackRecordedAt,
      toolCallMetadata: nil
    )
  }

  func timelineEntries(
    fallbackRecordedAt: String,
    toolCallMetadata: AcpToolCallTimelineMetadata?
  ) -> [TimelineEntry] {
    events
      .filter { $0.sessionId == sessionId }
      .compactMap { event in
        event.timelineEntry(
          acpID: acpId,
          fallbackRecordedAt: fallbackRecordedAt,
          toolCallMetadata: toolCallMetadata
        )
      }
  }
}

extension AcpConversationEvent {
  func timelineEntry(
    acpID: String,
    fallbackRecordedAt: String,
    toolCallMetadata: AcpToolCallTimelineMetadata?
  ) -> TimelineEntry? {
    let context = timelineEventContext(
      acpID: acpID,
      fallbackRecordedAt: fallbackRecordedAt,
      toolCallMetadata: toolCallMetadata
    )
    guard let context else {
      return nil
    }

    if let transcriptEntry = transcriptTimelineEntry(for: context) {
      return transcriptEntry
    }
    return toolTimelineEntry(for: context)
  }

  private struct TimelineEventContext {
    let event: [String: JSONValue]
    let type: String
    let identity: AcpTimelineIdentity
    let recordedAt: String
    let toolCallMetadata: AcpToolCallTimelineMetadata?
  }

  private func timelineEventContext(
    acpID: String,
    fallbackRecordedAt: String,
    toolCallMetadata: AcpToolCallTimelineMetadata?
  ) -> TimelineEventContext? {
    guard case .object(let event) = kind,
      let type = event.stringValue(for: "type")
    else {
      return nil
    }
    return TimelineEventContext(
      event: event,
      type: type,
      identity: Self.timelineIdentity(
        acpID: acpID,
        fallbackAgent: agent,
        toolCallMetadata: toolCallMetadata
      ),
      recordedAt: timestamp ?? fallbackRecordedAt,
      toolCallMetadata: toolCallMetadata
    )
  }

  private func transcriptTimelineEntry(
    for context: TimelineEventContext
  ) -> TimelineEntry? {
    let transcript = Self.transcriptDescriptor(
      for: context.type,
      event: context.event,
      identity: context.identity
    )
    guard let transcript else {
      return nil
    }
    return transcriptTimelineEntry(
      entryKind: transcript.entryKind,
      summary: transcript.summary,
      kind: kind,
      recordedAt: context.recordedAt,
      identity: context.identity
    )
  }

  private func toolTimelineEntry(
    for context: TimelineEventContext
  ) -> TimelineEntry? {
    guard let entryKind = Self.toolEntryKind(for: context.type, event: context.event) else {
      return nil
    }
    let toolName = context.event.stringValue(for: "tool_name") ?? "Tool"
    let status = Self.toolCallStatus(for: entryKind)
    let summary = Self.toolSummary(
      for: entryKind,
      toolName: toolName,
      identity: context.identity
    )

    return TimelineEntry(
      entryId: "acp-\(context.identity.agentId)-\(entryKind)-\(sequence)",
      recordedAt: context.recordedAt,
      kind: entryKind,
      sessionId: sessionId,
      agentId: context.identity.agentId,
      taskId: nil,
      summary: summary,
      payload: .object([
        "runtime": .string("acp"),
        "event": kind,
        "acp_timeline_identity": Self.acpTimelineIdentityPayload(
          from: context.identity,
          sequence: sequence
        ),
        "tool_call_timeline": .object([
          "tool_call_id": context.event["invocation_id"] ?? .null,
          "tool_name": .string(toolName),
          "status": .string(status),
          "acp_agent_id": .string(context.identity.acpAgentId),
          "agent_id": .string(context.identity.agentId),
          "agent_display_name": .string(context.identity.summaryActor),
          "capability_tags": .array(
            (context.toolCallMetadata?.capabilityTags ?? []).map(JSONValue.string)
          ),
          "sequence": .number(Double(sequence)),
          "stop_reason": context.event["stop_reason"] ?? .null,
        ]),
      ])
    )
  }

  private static func transcriptDescriptor(
    for type: String,
    event: [String: JSONValue],
    identity: AcpTimelineIdentity
  ) -> (entryKind: String, summary: String)? {
    switch type {
    case "user_prompt":
      return (
        "user_prompt",
        transcriptSummary(from: event["content"], fallback: "Prompt submitted")
      )
    case "assistant_text":
      return (
        "assistant_text",
        transcriptSummary(from: event["content"], fallback: "Assistant response")
      )
    default:
      return agentTranscriptDescriptor(for: type, event: event, identity: identity)
    }
  }

  private static func agentTranscriptDescriptor(
    for type: String,
    event: [String: JSONValue],
    identity: AcpTimelineIdentity
  ) -> (entryKind: String, summary: String)? {
    switch type {
    case "error":
      return (
        "agent_error",
        "\(identity.summaryActor) error: \(event.stringValue(for: "message") ?? "Unknown error")"
      )
    case "signal_received":
      let signalID = event.stringValue(for: "signal_id") ?? "signal"
      let command = event.stringValue(for: "command") ?? "unknown"
      return ("signal_received", "\(identity.summaryActor) picked up \(signalID) (\(command))")
    case "state_change":
      return ("agent_state_change", stateChangeSummary(prefix: identity.summaryActor, event: event))
    case "file_modification":
      return (
        "file_modification",
        fileModificationSummary(prefix: identity.summaryActor, event: event)
      )
    case "session_marker":
      let marker = event.stringValue(for: "marker") ?? "session"
      return ("agent_session_marker", "\(identity.summaryActor) marked \(marker)")
    case "watchdog_state":
      return (
        "agent_watchdog_state",
        watchdogSummary(prefix: identity.summaryActor, event: event)
      )
    case "permission_asked":
      return (
        "agent_permission_asked",
        permissionSummary(prefix: identity.summaryActor, event: event)
      )
    case "context_injected":
      return (
        "agent_context_injected",
        contextSummary(prefix: identity.summaryActor, event: event)
      )
    default:
      return nil
    }
  }

  private static func stateChangeSummary(prefix: String, event: [String: JSONValue]) -> String {
    let from = event.stringValue(for: "from") ?? "unknown"
    let to = event.stringValue(for: "to") ?? "unknown"
    return "\(prefix) state changed \(from) -> \(to)"
  }

  private static func fileModificationSummary(
    prefix: String,
    event: [String: JSONValue]
  ) -> String {
    let operation = event.stringValue(for: "operation") ?? "modified"
    let path = event.stringValue(for: "path") ?? "file"
    return "\(prefix) \(operation) \(path)"
  }

  private static func watchdogSummary(prefix: String, event: [String: JSONValue]) -> String {
    let from = event.stringValue(for: "from") ?? "unknown"
    let to = event.stringValue(for: "to") ?? "unknown"
    return "\(prefix) watchdog \(from) -> \(to)"
  }

  private static func permissionSummary(prefix: String, event: [String: JSONValue]) -> String {
    let tool = event.stringValue(for: "tool") ?? "tool"
    let scope = event.stringValue(for: "scope") ?? ""
    guard !scope.isEmpty else {
      return "\(prefix) asked for permission on \(tool)"
    }
    return "\(prefix) asked for permission on \(tool) (\(scope))"
  }

  private static func contextSummary(prefix: String, event: [String: JSONValue]) -> String {
    let actor = event.stringValue(for: "actor") ?? "system"
    let detail = event.stringValue(for: "summary") ?? ""
    guard !detail.isEmpty else {
      return "\(prefix) received context from \(actor)"
    }
    return "\(prefix) received context from \(actor): \(detail)"
  }

  private static func toolEntryKind(
    for type: String,
    event: [String: JSONValue]
  ) -> String? {
    switch type {
    case "tool_invocation":
      return "tool_invocation"
    case "tool_result_error":
      return "tool_result_error"
    case "tool_result":
      return event.boolValue(for: "is_error") == true ? "tool_result_error" : "tool_result"
    default:
      return nil
    }
  }

  private static func toolSummary(
    for entryKind: String,
    toolName: String,
    identity: AcpTimelineIdentity
  ) -> String {
    switch entryKind {
    case "tool_invocation":
      return "\(identity.summaryActor) invoked \(toolName)"
    case "tool_result_error":
      return "\(identity.summaryActor) received an error from \(toolName)"
    default:
      return "\(identity.summaryActor) received a result from \(toolName)"
    }
  }

  private static func toolCallStatus(for entryKind: String) -> String {
    switch entryKind {
    case "tool_invocation":
      return "started"
    case "tool_result_error":
      return "failed"
    default:
      return "completed"
    }
  }

  private func transcriptTimelineEntry(
    entryKind: String,
    summary: String,
    kind: JSONValue,
    recordedAt: String,
    identity: AcpTimelineIdentity
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: "acp-\(identity.agentId)-\(entryKind)-\(sequence)",
      recordedAt: recordedAt,
      kind: entryKind,
      sessionId: sessionId,
      agentId: identity.agentId,
      taskId: nil,
      summary: summary,
      payload: .object([
        "runtime": .string("acp"),
        "event": kind,
        "acp_timeline_identity": Self.acpTimelineIdentityPayload(
          from: identity,
          sequence: sequence
        ),
      ])
    )
  }

  private static func transcriptSummary(
    from value: JSONValue?,
    fallback: String
  ) -> String {
    guard case .string(let content)? = value else {
      return fallback
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func timelineIdentity(
    acpID: String,
    fallbackAgent: String,
    toolCallMetadata: AcpToolCallTimelineMetadata?
  ) -> AcpTimelineIdentity {
    let acpAgentId = toolCallMetadata?.acpAgentId ?? acpID
    let fallbackAgentID = fallbackAgent.isEmpty ? acpID : fallbackAgent
    let agentId = resolvedIdentityValue(
      metadataValue: toolCallMetadata?.agentId,
      acpID: acpID,
      fallbackAgent: fallbackAgent,
      fallbackValue: fallbackAgentID
    )
    let summaryActor = resolvedIdentityValue(
      metadataValue: toolCallMetadata?.displayName,
      acpID: acpID,
      fallbackAgent: fallbackAgent,
      fallbackValue: fallbackAgentID
    )
    return AcpTimelineIdentity(
      acpAgentId: acpAgentId,
      agentId: agentId,
      summaryActor: summaryActor
    )
  }

  private static func resolvedIdentityValue(
    metadataValue: String?,
    acpID: String,
    fallbackAgent: String,
    fallbackValue: String
  ) -> String {
    if let metadataValue,
      metadataValue != acpID || fallbackAgent.isEmpty
    {
      return metadataValue
    }
    return fallbackValue
  }

  private static func acpTimelineIdentityPayload(
    from identity: AcpTimelineIdentity,
    sequence: UInt64
  ) -> JSONValue {
    .object([
      "acp_agent_id": .string(identity.acpAgentId),
      "agent_id": .string(identity.agentId),
      "agent_display_name": .string(identity.summaryActor),
      "sequence": .number(Double(sequence)),
    ])
  }
}
