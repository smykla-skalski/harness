import Foundation

extension TimelineEntry {
  private static let managedAcpTranscriptResponseKinds: Set<String> = [
    "user_prompt",
    "assistant_text",
    "tool_invocation",
    "tool_result",
    "tool_result_error",
    "agent_error",
    "signal_received",
    "agent_state_change",
    "file_modification",
    "agent_session_marker",
    "agent_watchdog_state",
    "agent_permission_asked",
    "agent_context_injected",
  ]

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

  var isManagedRuntimeTranscriptEntry: Bool {
    guard Self.managedAcpTranscriptResponseKinds.contains(kind) else {
      return false
    }
    guard case .object(let payload) = payload else {
      return false
    }
    guard payload.stringValue(for: "runtime")?.isEmpty == false else {
      return false
    }
    guard case .object = payload["event"] else {
      return false
    }
    return true
  }

  var isAcpTranscriptResponseEntry: Bool {
    isAcpTranscriptEntry || isManagedRuntimeTranscriptEntry
  }

  func matchesDerivedAcpTranscriptHistory(sessionAgentIDs: Set<String>) -> Bool {
    if isAcpTranscriptEntry {
      return true
    }
    guard
      isManagedRuntimeTranscriptEntry,
      let agentId,
      sessionAgentIDs.contains(agentId)
    else {
      return false
    }
    return true
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

extension Collection where Element == TimelineEntry {
  public func partitionedByAgentID() -> [String: [TimelineEntry]] {
    var partition: [String: [TimelineEntry]] = [:]
    partition.reserveCapacity(underestimatedCount)
    for entry in self {
      guard let agentID = entry.agentId else { continue }
      partition[agentID, default: []].append(entry)
    }
    return partition
  }
}
