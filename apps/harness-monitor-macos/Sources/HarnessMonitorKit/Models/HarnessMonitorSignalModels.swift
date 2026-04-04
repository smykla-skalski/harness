import Foundation

public enum SignalPriority: String, Codable, CaseIterable, Sendable {
  case low
  case normal
  case high
  case urgent

  public var title: String {
    switch self {
    case .low:
      "Low"
    case .normal:
      "Normal"
    case .high:
      "High"
    case .urgent:
      "Urgent"
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
  case acknowledged
  case rejected
  case deferred
  case expired

  public var title: String {
    switch self {
    case .pending:
      "Pending"
    case .acknowledged:
      "Acknowledged"
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

public struct TimelineEntry: Codable, Equatable, Identifiable, Sendable {
  public let entryId: String
  public let recordedAt: String
  public let kind: String
  public let sessionId: String
  public let agentId: String?
  public let taskId: String?
  public let summary: String
  public let payload: JSONValue

  public var id: String { entryId }
}

public struct SessionsUpdatedPayload: Codable, Equatable, Sendable {
  public let projects: [ProjectSummary]
  public let sessions: [SessionSummary]
}

public struct SessionUpdatedPayload: Codable, Equatable, Sendable {
  public let detail: SessionDetail
  public let timeline: [TimelineEntry]?
  public let extensionsPending: Bool?
}

public struct StreamEvent: Codable, Equatable, Identifiable, Sendable {
  public let event: String
  public let recordedAt: String
  public let sessionId: String?
  public let payload: JSONValue
  private let stableID = UUID()

  public var id: UUID { stableID }
  enum CodingKeys: String, CodingKey { case event, recordedAt, sessionId, payload }

  public init(event: String, recordedAt: String, sessionId: String?, payload: JSONValue) {
    self.event = event
    self.recordedAt = recordedAt
    self.sessionId = sessionId
    self.payload = payload
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.event == rhs.event && lhs.recordedAt == rhs.recordedAt
      && lhs.sessionId == rhs.sessionId && lhs.payload == rhs.payload
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

public enum HarnessMonitorPushEventError: Error, LocalizedError, Equatable {
  case missingSessionID(String)

  public var errorDescription: String? {
    switch self {
    case .missingSessionID(let event):
      "Missing session ID for daemon push event '\(event)'."
    }
  }
}

public struct DaemonPushEvent: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    case ready
    case sessionsUpdated(SessionsUpdatedPayload)
    case sessionUpdated(SessionUpdatedPayload)
    case sessionExtensions(SessionExtensionsPayload)
    case unknown(eventName: String, payload: JSONValue)
  }

  public let recordedAt: String
  public let sessionId: String?
  public let kind: Kind
  private let stableID = UUID()

  public var id: UUID { stableID }

  public init(recordedAt: String, sessionId: String?, kind: Kind) {
    self.recordedAt = recordedAt
    self.sessionId = sessionId
    self.kind = kind
  }

  public init(streamEvent: StreamEvent) throws {
    switch streamEvent.event {
    case "ready":
      self.init(
        recordedAt: streamEvent.recordedAt,
        sessionId: streamEvent.sessionId,
        kind: .ready
      )
    case "sessions_updated":
      self.init(
        recordedAt: streamEvent.recordedAt,
        sessionId: nil,
        kind: .sessionsUpdated(try streamEvent.decodePayload(as: SessionsUpdatedPayload.self))
      )
    case "session_updated":
      guard let sessionId = streamEvent.sessionId else {
        throw HarnessMonitorPushEventError.missingSessionID(streamEvent.event)
      }
      self.init(
        recordedAt: streamEvent.recordedAt,
        sessionId: sessionId,
        kind: .sessionUpdated(try streamEvent.decodePayload(as: SessionUpdatedPayload.self))
      )
    case "session_extensions":
      guard let sessionId = streamEvent.sessionId else {
        throw HarnessMonitorPushEventError.missingSessionID(streamEvent.event)
      }
      self.init(
        recordedAt: streamEvent.recordedAt,
        sessionId: sessionId,
        kind: .sessionExtensions(
          try streamEvent.decodePayload(as: SessionExtensionsPayload.self)
        )
      )
    default:
      self.init(
        recordedAt: streamEvent.recordedAt,
        sessionId: streamEvent.sessionId,
        kind: .unknown(eventName: streamEvent.event, payload: streamEvent.payload)
      )
    }
  }

  public static func ready(
    recordedAt: String,
    sessionId: String? = nil
  ) -> Self {
    Self(recordedAt: recordedAt, sessionId: sessionId, kind: .ready)
  }

  public static func sessionsUpdated(
    recordedAt: String,
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) -> Self {
    Self(
      recordedAt: recordedAt,
      sessionId: nil,
      kind: .sessionsUpdated(
        SessionsUpdatedPayload(projects: projects, sessions: sessions)
      )
    )
  }

  public static func sessionUpdated(
    recordedAt: String,
    sessionId: String,
    detail: SessionDetail,
    timeline: [TimelineEntry]? = nil,
    extensionsPending: Bool? = nil
  ) -> Self {
    Self(
      recordedAt: recordedAt,
      sessionId: sessionId,
      kind: .sessionUpdated(
        SessionUpdatedPayload(
          detail: detail,
          timeline: timeline,
          extensionsPending: extensionsPending
        )
      )
    )
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.recordedAt == rhs.recordedAt
      && lhs.sessionId == rhs.sessionId
      && lhs.kind == rhs.kind
  }
}
