import Foundation

extension [String: JSONValue] {
  func stringValue(for key: String) -> String? {
    guard case .string(let value)? = self[key] else {
      return nil
    }
    return value
  }

  func boolValue(for key: String) -> Bool? {
    guard case .bool(let value)? = self[key] else {
      return nil
    }
    return value
  }

  func arrayStringValues(for key: String) -> [String] {
    guard case .array(let values)? = self[key] else {
      return []
    }
    return values.compactMap {
      guard case .string(let value) = $0 else {
        return nil
      }
      return value
    }
  }

  func uint64Value(for key: String) -> UInt64? {
    guard case .number(let value)? = self[key], value >= 0 else {
      return nil
    }
    return UInt64(value)
  }
}

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

extension StreamEvent {
  private static let payloadEncoder = JSONEncoder()
  private static let payloadDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  public func decodePayload<Payload: Decodable>(as type: Payload.Type) throws -> Payload {
    let data = try Self.payloadEncoder.encode(payload)
    return try Self.payloadDecoder.decode(type, from: data)
  }
}
