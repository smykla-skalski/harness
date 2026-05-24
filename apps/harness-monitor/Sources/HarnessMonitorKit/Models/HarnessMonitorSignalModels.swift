import Foundation

public enum SignalPriority: String, Codable, CaseIterable, Sendable {
  case low
  case normal
  case high
  case urgent

  public var title: String {
    switch self {
    case .low: "Low"
    case .normal: "Normal"
    case .high: "High"
    case .urgent: "Urgent"
    }
  }
}

public struct DeliveryConfig: Codable, Equatable, Sendable {
  public let maxRetries: Int
  public let retryCount: Int
  public let idempotencyKey: String?
}

public enum JSONValue: Codable, Equatable, Sendable {
  case array([Self])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: Self])
  case string(String)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode([String: Self].self) {
      self = .object(value)
    } else if let value = try? container.decode([Self].self) {
      self = .array(value)
    } else if container.decodeNil() {
      self = .null
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON payload",
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }

  public var isStructurallyEmpty: Bool {
    switch self {
    case .null: true
    case .object(let dict): dict.isEmpty
    case .array(let items): items.isEmpty
    case .bool, .number, .string: false
    }
  }
}

public struct SignalPayload: Codable, Equatable, Sendable {
  public let message: String
  public let actionHint: String?
  public let relatedFiles: [String]
  public let metadata: JSONValue

  public init(
    message: String,
    actionHint: String?,
    relatedFiles: [String],
    metadata: JSONValue
  ) {
    self.message = message
    self.actionHint = actionHint
    self.relatedFiles = relatedFiles
    self.metadata = metadata
  }

  enum CodingKeys: String, CodingKey {
    case message
    case actionHint
    case relatedFiles
    case metadata
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    message = try container.decode(String.self, forKey: .message)
    actionHint = try container.decodeIfPresent(String.self, forKey: .actionHint)
    relatedFiles = try container.decodeIfPresent([String].self, forKey: .relatedFiles) ?? []
    metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata) ?? .object([:])
  }
}

public struct Signal: Codable, Equatable, Identifiable, Sendable {
  public let signalId: String
  public let version: Int
  public let createdAt: String
  public let expiresAt: String
  public let sourceAgent: String
  public let command: String
  public let priority: SignalPriority
  public let payload: SignalPayload
  public let delivery: DeliveryConfig

  public var id: String { signalId }
}

public enum AckResult: String, Codable, CaseIterable, Sendable {
  case accepted
  case rejected
  case deferred
  case expired

  public var title: String {
    switch self {
    case .accepted:
      "Accepted"
    case .rejected:
      "Rejected"
    case .deferred:
      "Deferred"
    case .expired:
      "Expired"
    }
  }
}

public struct SignalAck: Codable, Equatable, Identifiable, Sendable {
  public let signalId: String
  public let acknowledgedAt: String
  public let result: AckResult
  public let agent: String
  public let sessionId: String
  public let details: String?

  public var id: String { signalId }
}

public enum SessionSignalStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case delivered
  case rejected
  case deferred
  case expired

  init?(rawOrLegacyValue value: String) {
    switch value {
    case "acknowledged":
      self = .delivered
    default:
      self.init(rawValue: value)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let status = Self(rawOrLegacyValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid signal status: \(value)"
      )
    }
    self = status
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var title: String {
    switch self {
    case .pending:
      "Pending"
    case .delivered:
      "Delivered"
    case .rejected:
      "Rejected"
    case .deferred:
      "Deferred"
    case .expired:
      "Expired"
    }
  }
}

public struct SessionSignalRecord: Codable, Equatable, Identifiable, Sendable {
  public let runtime: String
  public let agentId: String
  public let sessionId: String
  public let status: SessionSignalStatus
  public let signal: Signal
  public let acknowledgment: SignalAck?

  public var id: String { signal.signalId }
}

extension SessionSignalRecord {
  public func effectiveStatus(now: Date = .now) -> SessionSignalStatus {
    guard status == .pending else { return status }
    guard let expires = expiresAtDate else { return status }
    return expires < now ? .expired : .pending
  }

  public var effectiveStatus: SessionSignalStatus {
    effectiveStatus(now: .now)
  }

  public var expiresAtDate: Date? {
    Self.parseExpiresAt(signal.expiresAt)
  }

  static func parseExpiresAt(_ value: String) -> Date? {
    let withFraction = Date.ISO8601FormatStyle().year().month().day()
      .timeZone(separator: .omitted)
      .time(includingFractionalSeconds: true)
    if let date = try? withFraction.parse(value) {
      return date
    }
    return try? Date.ISO8601FormatStyle().parse(value)
  }
}
