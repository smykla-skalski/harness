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
    "agent_turn_ended",
    "agent_context_usage",
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

  var isManagedRuntimeTranscriptResponseEntry: Bool {
    isAcpTranscriptEntry || isManagedRuntimeTranscriptEntry
  }

  var isAcpTranscriptResponseEntry: Bool {
    isManagedRuntimeTranscriptResponseEntry
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

  public func codexTimelineIdentityMetadata() -> CodexTimelineIdentityMetadata? {
    guard let payloadMetadata = codexTimelinePayloadMetadata(),
      let runID = payloadMetadata.stringValue(for: "run_id")
    else {
      return nil
    }
    return CodexTimelineIdentityMetadata(
      runID: runID,
      agentID: payloadMetadata.stringValue(for: "agent_id") ?? agentId,
      agentDisplayName: payloadMetadata.stringValue(for: "agent_display_name"),
      threadID: payloadMetadata.stringValue(for: "thread_id"),
      turnID: payloadMetadata.stringValue(for: "turn_id")
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

  private func codexTimelinePayloadMetadata() -> [String: JSONValue]? {
    guard case .object(let payload) = payload,
      case .object(let metadata)? = payload["codex_timeline_identity"]
    else {
      return nil
    }
    return metadata
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
