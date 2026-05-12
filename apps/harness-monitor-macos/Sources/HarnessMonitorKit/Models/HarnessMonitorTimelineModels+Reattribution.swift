import Foundation

extension TimelineEntry {
  public func reattributedAcpTimelineEntry(
    sessionAgentID: String,
    displayName: String
  ) -> TimelineEntry {
    let updatedEntryID =
      if let sequence = acpTimelineIdentityMetadata()?.sequence {
        "acp-\(sessionAgentID)-\(kind)-\(sequence)"
      } else {
        entryId
      }

    guard case .object(var payloadObject) = payload else {
      return TimelineEntry(
        entryId: updatedEntryID,
        recordedAt: recordedAt,
        kind: kind,
        sessionId: sessionId,
        agentId: sessionAgentID,
        taskId: taskId,
        summary: summary,
        payload: payload
      )
    }

    if case .object(var metadata)? = payloadObject["acp_timeline_identity"] {
      metadata["agent_id"] = .string(sessionAgentID)
      metadata["agent_display_name"] = .string(displayName)
      payloadObject["acp_timeline_identity"] = .object(metadata)
    }
    if case .object(var metadata)? = payloadObject["tool_call_timeline"] {
      metadata["agent_id"] = .string(sessionAgentID)
      metadata["agent_display_name"] = .string(displayName)
      payloadObject["tool_call_timeline"] = .object(metadata)
    }
    if case .object(var metadata)? = payloadObject["codex_timeline_identity"] {
      metadata["agent_id"] = .string(sessionAgentID)
      metadata["agent_display_name"] = .string(displayName)
      payloadObject["codex_timeline_identity"] = .object(metadata)
    }

    return TimelineEntry(
      entryId: updatedEntryID,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: sessionId,
      agentId: sessionAgentID,
      taskId: taskId,
      summary: reattributedAcpTimelineSummary(displayName: displayName),
      payload: .object(payloadObject)
    )
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
    if let transcriptSummary = Self.reattributedTranscriptSummary(kind: kind, event: event) {
      return transcriptSummary
    }
    if let agentSummary = Self.reattributedAgentEventSummary(
      kind: kind,
      displayName: displayName,
      event: event
    ) {
      return agentSummary
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
    event: [String: JSONValue]
  ) -> String? {
    switch kind {
    case "user_prompt":
      return Self.transcriptSummary(from: event["content"], fallback: "Prompt submitted")
    case "assistant_text":
      return Self.transcriptSummary(from: event["content"], fallback: "Assistant response")
    default:
      return nil
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
      let from = event.stringValue(for: "from") ?? "unknown"
      let to = event.stringValue(for: "to") ?? "unknown"
      return "\(displayName) state changed \(from) -> \(to)"
    case "file_modification":
      let operation = event.stringValue(for: "operation") ?? "modified"
      let path = event.stringValue(for: "path") ?? "file"
      return "\(displayName) \(operation) \(path)"
    case "agent_session_marker":
      return "\(displayName) marked \(event.stringValue(for: "marker") ?? "session")"
    case "agent_watchdog_state":
      return Self.reattributedWatchdogSummary(displayName: displayName, event: event)
    case "agent_permission_asked":
      return Self.reattributedPermissionSummary(displayName: displayName, event: event)
    case "agent_context_injected":
      return Self.reattributedContextSummary(displayName: displayName, event: event)
    default:
      return nil
    }
  }

  private static func reattributedToolSummary(
    kind: String,
    displayName: String,
    event: [String: JSONValue]
  ) -> String? {
    switch kind {
    case "tool_invocation":
      return "\(displayName) invoked \(event.stringValue(for: "tool_name") ?? "Tool")"
    case "tool_result_error":
      let toolName = event.stringValue(for: "tool_name") ?? "Tool"
      return "\(displayName) received an error from \(toolName)"
    case "tool_result":
      let toolName = event.stringValue(for: "tool_name") ?? "Tool"
      return event.boolValue(for: "is_error") == true
        ? "\(displayName) received an error from \(toolName)"
        : "\(displayName) received a result from \(toolName)"
    default:
      return nil
    }
  }

  private static func reattributedWatchdogSummary(
    displayName: String,
    event: [String: JSONValue]
  ) -> String {
    let from = event.stringValue(for: "from") ?? "unknown"
    let to = event.stringValue(for: "to") ?? "unknown"
    let base = "\(displayName) watchdog \(from) -> \(to)"
    guard
      let reason = event.stringValue(for: "reason")?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      !reason.isEmpty
    else {
      return base
    }
    return "\(base) (\(reason))"
  }

  private static func reattributedPermissionSummary(
    displayName: String,
    event: [String: JSONValue]
  ) -> String {
    let tool = event.stringValue(for: "tool") ?? "tool"
    let scope = event.stringValue(for: "scope") ?? ""
    guard !scope.isEmpty else {
      return "\(displayName) asked for permission on \(tool)"
    }
    return "\(displayName) asked for permission on \(tool) (\(scope))"
  }

  private static func reattributedContextSummary(
    displayName: String,
    event: [String: JSONValue]
  ) -> String {
    let actor = event.stringValue(for: "actor") ?? "system"
    let detail = event.stringValue(for: "summary") ?? ""
    guard !detail.isEmpty else {
      return "\(displayName) received context from \(actor)"
    }
    return "\(displayName) received context from \(actor): \(detail)"
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
