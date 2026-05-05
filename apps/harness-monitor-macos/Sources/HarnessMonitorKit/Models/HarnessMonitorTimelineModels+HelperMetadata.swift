import Foundation

public struct AcpTimelineIdentityMetadata: Equatable, Sendable {
  public let acpAgentID: String
  public let agentID: String?
  public let agentDisplayName: String?
  public let sequence: UInt64?

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
