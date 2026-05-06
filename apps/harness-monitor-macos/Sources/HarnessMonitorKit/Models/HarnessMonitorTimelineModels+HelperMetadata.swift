import Foundation

public struct AcpTimelineIdentityMetadata: Equatable, Sendable {
  public let acpAgentID: String
  public let agentID: String?
  public let agentDisplayName: String?
  public let sequence: UInt64?

  public var managedAgentID: String { acpAgentID }
  public var sessionAgentID: String? { agentID }

  public init(
    acpAgentID: String,
    agentID: String?,
    agentDisplayName: String?,
    sequence: UInt64?
  ) {
    self.acpAgentID = acpAgentID
    self.agentID = agentID
    self.agentDisplayName = agentDisplayName
    self.sequence = sequence
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

  public var managedAgentID: String? { acpAgentID }
  public var sessionAgentID: String? { agentID }

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
