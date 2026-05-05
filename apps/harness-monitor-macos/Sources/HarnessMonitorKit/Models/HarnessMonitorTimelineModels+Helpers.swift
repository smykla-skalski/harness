import Foundation

public struct ToolCallTimelineEntryMetadata: Equatable, Sendable {
  public let rowID: String
  public let phaseID: String
  public let toolCallID: String
  public let toolName: String
  public let status: String
  public let acpAgentID: String?
  public let agentID: String?
  public let agentDisplayName: String?
  public let capabilityTags: [String]
  public let sequence: UInt64?
  public let stopReason: String?

  public init(
    rowID: String,
    phaseID: String,
    toolCallID: String,
    toolName: String,
    status: String,
    acpAgentID: String?,
    agentID: String?,
    agentDisplayName: String?,
    capabilityTags: [String],
    sequence: UInt64?,
    stopReason: String?
  ) {
    self.rowID = rowID
    self.phaseID = phaseID
    self.toolCallID = toolCallID
    self.toolName = toolName
    self.status = status
    self.acpAgentID = acpAgentID
    self.agentID = agentID
    self.agentDisplayName = agentDisplayName
    self.capabilityTags = capabilityTags
    self.sequence = sequence
    self.stopReason = stopReason
  }
}

extension TimelineEntry {
  public var isAcpTranscriptEntry: Bool {
    if acpTimelineIdentityMetadata() != nil {
      return true
    }
    if toolCallTimelineEntryMetadata()?.acpAgentID != nil {
      return true
    }
    guard case .object(let payload) = payload else {
      return false
    }
    return payload.stringValue(for: "runtime") == "acp"
  }

  public func acpTimelineIdentityMetadata() -> AcpTimelineIdentityMetadata? {
    if let payloadMetadata = acpTimelinePayloadMetadata(),
      let acpAgentID = payloadMetadata.stringValue(for: "acp_agent_id")
    {
      return AcpTimelineIdentityMetadata(
        acpAgentID: acpAgentID,
        agentID: payloadMetadata.stringValue(for: "agent_id") ?? agentId,
        agentDisplayName: payloadMetadata.stringValue(for: "agent_display_name"),
        sequence: payloadMetadata.uint64Value(for: "sequence")
      )
    }

    guard let metadata = toolCallTimelineEntryMetadata(),
      let acpAgentID = metadata.acpAgentID
    else {
      return nil
    }
    return AcpTimelineIdentityMetadata(
      acpAgentID: acpAgentID,
      agentID: metadata.agentID,
      agentDisplayName: metadata.agentDisplayName,
      sequence: metadata.sequence
    )
  }

  public func reattributedAcpTimelineEntry(
    agentID: String,
    displayName: String
  ) -> TimelineEntry {
    let updatedEntryID =
      if let sequence = acpTimelineIdentityMetadata()?.sequence {
        "acp-\(agentID)-\(kind)-\(sequence)"
      } else {
        entryId
      }

    guard case .object(var payloadObject) = payload else {
      return TimelineEntry(
        entryId: updatedEntryID,
        recordedAt: recordedAt,
        kind: kind,
        sessionId: sessionId,
        agentId: agentID,
        taskId: taskId,
        summary: summary,
        payload: payload
      )
    }

    if case .object(var payloadMetadata)? = payloadObject["acp_timeline_identity"] {
      payloadMetadata["agent_id"] = .string(agentID)
      payloadMetadata["agent_display_name"] = .string(displayName)
      payloadObject["acp_timeline_identity"] = .object(payloadMetadata)
    }

    if case .object(var toolCallMetadata)? = payloadObject["tool_call_timeline"] {
      toolCallMetadata["agent_id"] = .string(agentID)
      toolCallMetadata["agent_display_name"] = .string(displayName)
      payloadObject["tool_call_timeline"] = .object(toolCallMetadata)
    }

    return TimelineEntry(
      entryId: updatedEntryID,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: sessionId,
      agentId: agentID,
      taskId: taskId,
      summary: reattributedAcpTimelineSummary(displayName: displayName),
      payload: .object(payloadObject)
    )
  }

  public func toolCallTimelineEntryMetadata() -> ToolCallTimelineEntryMetadata? {
    let payloadMetadata = toolCallTimelinePayloadMetadata()
    let event = toolCallTimelineEventPayload()
    let toolCallID =
      payloadMetadata?.stringValue(for: "tool_call_id")
      ?? event?.stringValue(for: "invocation_id")
    guard let toolCallID, !toolCallID.isEmpty else {
      return nil
    }

    let status =
      payloadMetadata?.stringValue(for: "status")
      ?? Self.derivedToolCallStatus(for: kind, event: event)
    guard let status else {
      return nil
    }

    let agentNamespace =
      payloadMetadata?.stringValue(for: "acp_agent_id")
      ?? payloadMetadata?.stringValue(for: "agent_id")
      ?? agentId
      ?? "session"
    let rowID = [sessionId, agentNamespace, toolCallID].joined(separator: "::")
    let toolName =
      payloadMetadata?.stringValue(for: "tool_name")
      ?? event?.stringValue(for: "tool_name")
      ?? "Tool"

    return ToolCallTimelineEntryMetadata(
      rowID: rowID,
      phaseID: "\(rowID)::\(status)",
      toolCallID: toolCallID,
      toolName: toolName,
      status: status,
      acpAgentID: payloadMetadata?.stringValue(for: "acp_agent_id"),
      agentID: payloadMetadata?.stringValue(for: "agent_id") ?? agentId,
      agentDisplayName: payloadMetadata?.stringValue(for: "agent_display_name"),
      capabilityTags: payloadMetadata?.arrayStringValues(for: "capability_tags") ?? [],
      sequence: payloadMetadata?.uint64Value(for: "sequence"),
      stopReason: payloadMetadata?.stringValue(for: "stop_reason")
    )
  }

  private func toolCallTimelinePayloadMetadata() -> [String: JSONValue]? {
    guard case .object(let payload) = payload,
      case .object(let metadata)? = payload["tool_call_timeline"]
    else {
      return nil
    }
    return metadata
  }

  private func acpTimelinePayloadMetadata() -> [String: JSONValue]? {
    guard case .object(let payload) = payload,
      case .object(let metadata)? = payload["acp_timeline_identity"]
    else {
      return nil
    }
    return metadata
  }

  private func acpConversationEventPayload() -> [String: JSONValue]? {
    guard case .object(let payload) = payload,
      case .object(let event)? = payload["event"]
    else {
      return nil
    }
    return event
  }

  private func reattributedAcpTimelineSummary(displayName: String) -> String {
    guard let event = acpConversationEventPayload() else {
      return summary
    }
    if let transcriptSummary = Self.reattributedTranscriptSummary(
      kind: kind,
      displayName: displayName,
      event: event
    ) {
      return transcriptSummary
    }
    if let toolSummary = Self.reattributedToolSummary(
      kind: kind,
      displayName: displayName,
      event: event
    ) {
      return toolSummary
    }
    return summary
  }

  private static func reattributedTranscriptSummary(
    kind: String,
    displayName: String,
    event: [String: JSONValue]
  ) -> String? {
    switch kind {
    case "user_prompt":
      return transcriptSummary(from: event["content"], fallback: "Prompt submitted")
    case "assistant_text":
      return transcriptSummary(from: event["content"], fallback: "Assistant response")
    default:
      return reattributedAgentEventSummary(
        kind: kind,
        displayName: displayName,
        event: event
      )
    }
  }

  private static func reattributedAgentEventSummary(
    kind: String,
    displayName: String,
    event: [String: JSONValue]
  ) -> String? {
    switch kind {
    case "agent_error":
      return "\(displayName) error: \(event.stringValue(for: "message") ?? "Unknown error")"
    case "signal_received":
      let signalID = event.stringValue(for: "signal_id") ?? "signal"
      let command = event.stringValue(for: "command") ?? "unknown"
      return "\(displayName) picked up \(signalID) (\(command))"
    case "agent_state_change":
      return reattributedStateChangeSummary(prefix: displayName, event: event)
    case "file_modification":
      return reattributedFileModificationSummary(prefix: displayName, event: event)
    case "agent_session_marker":
      let marker = event.stringValue(for: "marker") ?? "session"
      return "\(displayName) marked \(marker)"
    case "agent_watchdog_state":
      return reattributedWatchdogSummary(prefix: displayName, event: event)
    case "agent_permission_asked":
      return reattributedPermissionSummary(prefix: displayName, event: event)
    case "agent_context_injected":
      return reattributedContextSummary(prefix: displayName, event: event)
    default:
      return nil
    }
  }

  private static func reattributedStateChangeSummary(
    prefix: String,
    event: [String: JSONValue]
  ) -> String {
    let from = event.stringValue(for: "from") ?? "unknown"
    let to = event.stringValue(for: "to") ?? "unknown"
    return "\(prefix) state changed \(from) -> \(to)"
  }

  private static func reattributedFileModificationSummary(
    prefix: String,
    event: [String: JSONValue]
  ) -> String {
    let operation = event.stringValue(for: "operation") ?? "modified"
    let path = event.stringValue(for: "path") ?? "file"
    return "\(prefix) \(operation) \(path)"
  }

  private static func reattributedWatchdogSummary(
    prefix: String,
    event: [String: JSONValue]
  ) -> String {
    let from = event.stringValue(for: "from") ?? "unknown"
    let to = event.stringValue(for: "to") ?? "unknown"
    return "\(prefix) watchdog \(from) -> \(to)"
  }

  private static func reattributedPermissionSummary(
    prefix: String,
    event: [String: JSONValue]
  ) -> String {
    let tool = event.stringValue(for: "tool") ?? "tool"
    let scope = event.stringValue(for: "scope") ?? ""
    guard !scope.isEmpty else {
      return "\(prefix) asked for permission on \(tool)"
    }
    return "\(prefix) asked for permission on \(tool) (\(scope))"
  }

  private static func reattributedContextSummary(
    prefix: String,
    event: [String: JSONValue]
  ) -> String {
    let actor = event.stringValue(for: "actor") ?? "system"
    let detail = event.stringValue(for: "summary") ?? ""
    guard !detail.isEmpty else {
      return "\(prefix) received context from \(actor)"
    }
    return "\(prefix) received context from \(actor): \(detail)"
  }

  private static func reattributedToolSummary(
    kind: String,
    displayName: String,
    event: [String: JSONValue]
  ) -> String? {
    let toolName = event.stringValue(for: "tool_name") ?? "Tool"
    switch kind {
    case "tool_invocation":
      return "\(displayName) invoked \(toolName)"
    case "tool_result_error":
      return "\(displayName) received an error from \(toolName)"
    case "tool_result":
      return event.boolValue(for: "is_error") == true
        ? "\(displayName) received an error from \(toolName)"
        : "\(displayName) received a result from \(toolName)"
    default:
      return nil
    }
  }

  private func toolCallTimelineEventPayload() -> [String: JSONValue]? {
    let canonicalKinds = ["tool_invocation", "tool_result", "tool_result_error"]
    guard canonicalKinds.contains(kind) || kind == "conversation_event",
      case .object(let payload) = payload
    else {
      return nil
    }
    let eventPayload = payload["event"] ?? payload["kind"]
    guard case .object(let event)? = eventPayload else {
      return nil
    }
    return event
  }

  private static func derivedToolCallStatus(
    for entryKind: String,
    event: [String: JSONValue]?
  ) -> String? {
    switch entryKind {
    case "tool_invocation":
      return "started"
    case "tool_result_error":
      return "failed"
    case "tool_result":
      return event?.boolValue(for: "is_error") == true ? "failed" : "completed"
    case "conversation_event":
      guard let eventType = event?.stringValue(for: "type") else {
        return nil
      }
      switch eventType {
      case "tool_invocation":
        return "started"
      case "tool_result":
        return event?.boolValue(for: "is_error") == true ? "failed" : "completed"
      default:
        return nil
      }
    default:
      return nil
    }
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
}
