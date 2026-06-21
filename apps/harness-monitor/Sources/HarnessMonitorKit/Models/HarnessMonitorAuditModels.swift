import Foundation

public struct HarnessMonitorAuditEvent: Identifiable, Codable, Equatable, Sendable {
  public var id: String
  public var recordedAt: Date
  public var source: String
  public var category: String
  public var kind: String
  public var severity: String
  public var outcome: String
  public var title: String
  public var summary: String
  public var subject: String?
  public var actor: String?
  public var correlationID: String?
  public var actionKey: String?
  public var payloadJSON: JSONValue?
  public var legacyMessage: String?
  public var relatedURLs: [String]

  public init(
    id: String,
    recordedAt: Date,
    source: String,
    category: String,
    kind: String,
    severity: String,
    outcome: String,
    title: String,
    summary: String,
    subject: String? = nil,
    actor: String? = nil,
    correlationID: String? = nil,
    actionKey: String? = nil,
    payloadJSON: JSONValue? = nil,
    legacyMessage: String? = nil,
    relatedURLs: [String] = []
  ) {
    self.id = id
    self.recordedAt = recordedAt
    self.source = source
    self.category = category
    self.kind = kind
    self.severity = severity
    self.outcome = outcome
    self.title = title
    self.summary = summary
    self.subject = subject
    self.actor = actor
    self.correlationID = correlationID
    self.actionKey = actionKey
    self.payloadJSON = payloadJSON
    self.legacyMessage = legacyMessage
    self.relatedURLs = relatedURLs
  }

  public var dedupeKey: String {
    "\(source):\(id)"
  }

  public var notificationEntryID: String? {
    guard id.hasPrefix(Self.notificationIDPrefix) else { return nil }
    return String(id.dropFirst(Self.notificationIDPrefix.count))
  }

  public func payloadJSONString(redacted: Bool = true, pretty: Bool = true) -> String? {
    guard let payloadJSON else { return nil }
    let encoder = JSONEncoder()
    if pretty {
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    } else {
      encoder.outputFormatting = [.sortedKeys]
    }
    guard
      let data = try? encoder.encode(payloadJSON),
      var text = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    if redacted {
      text = redactSupervisorPayloadJSON(text)
    }
    return text
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordedAt
    case source
    case category
    case kind
    case severity
    case outcome
    case title
    case summary
    case subject
    case actor
    case correlationID = "correlationId"
    case actionKey
    case payloadJSON = "payloadJson"
    case legacyMessage
    case relatedURLs = "relatedUrls"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    recordedAt = try Self.decodeDate(from: container, forKey: .recordedAt)
    source = try container.decode(String.self, forKey: .source)
    category = try container.decode(String.self, forKey: .category)
    kind = try container.decode(String.self, forKey: .kind)
    severity = try container.decode(String.self, forKey: .severity)
    outcome = try container.decode(String.self, forKey: .outcome)
    title = try container.decode(String.self, forKey: .title)
    summary = try container.decode(String.self, forKey: .summary)
    subject = try container.decodeIfPresent(String.self, forKey: .subject)
    actor = try container.decodeIfPresent(String.self, forKey: .actor)
    correlationID = try container.decodeIfPresent(String.self, forKey: .correlationID)
    actionKey = try container.decodeIfPresent(String.self, forKey: .actionKey)
    payloadJSON = try container.decodeIfPresent(JSONValue.self, forKey: .payloadJSON)
    legacyMessage = try container.decodeIfPresent(String.self, forKey: .legacyMessage)
    relatedURLs = try container.decodeIfPresent([String].self, forKey: .relatedURLs) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(Self.encodeDate(recordedAt), forKey: .recordedAt)
    try container.encode(source, forKey: .source)
    try container.encode(category, forKey: .category)
    try container.encode(kind, forKey: .kind)
    try container.encode(severity, forKey: .severity)
    try container.encode(outcome, forKey: .outcome)
    try container.encode(title, forKey: .title)
    try container.encode(summary, forKey: .summary)
    try container.encodeIfPresent(subject, forKey: .subject)
    try container.encodeIfPresent(actor, forKey: .actor)
    try container.encodeIfPresent(correlationID, forKey: .correlationID)
    try container.encodeIfPresent(actionKey, forKey: .actionKey)
    try container.encodeIfPresent(payloadJSON, forKey: .payloadJSON)
    try container.encodeIfPresent(legacyMessage, forKey: .legacyMessage)
    try container.encode(relatedURLs, forKey: .relatedURLs)
  }
}

public enum HarnessMonitorAuditEventClipboardError: LocalizedError, Sendable {
  case encodedJSONIsNotUTF8

  public var errorDescription: String? {
    switch self {
    case .encodedJSONIsNotUTF8:
      "The encoded audit event JSON was not valid UTF-8."
    }
  }
}
