import Foundation

public struct HarnessMonitorAuditDateRange: Codable, Equatable, Sendable {
  public var start: String?
  public var end: String?

  public init(start: String? = nil, end: String? = nil) {
    self.start = start
    self.end = end
  }
}

struct DashboardReviewActionAuditBackfillEntry: Codable, Equatable, Sendable {
  enum Outcome: String, Codable, Equatable, Sendable {
    case success
    case warning
    case failure
  }

  let id: String
  let title: String
  let summary: String
  let outcome: Outcome
  let messages: [String]
  let recordedAt: Date
}

extension DashboardReviewActionAuditBackfillEntry.Outcome {
  var auditOutcome: String {
    switch self {
    case .success:
      "success"
    case .warning:
      "warning"
    case .failure:
      "failure"
    }
  }

  var auditSeverity: String {
    switch self {
    case .success:
      "info"
    case .warning:
      "warning"
    case .failure:
      "error"
    }
  }
}

public struct HarnessMonitorAuditEventsRequest: Codable, Equatable, Sendable {
  public var limit: Int?
  public var before: String?
  public var dateRange: HarnessMonitorAuditDateRange?
  public var sources: [String]
  public var categories: [String]
  public var severities: [String]
  public var outcomes: [String]
  public var actionKeys: [String]
  public var subject: String?
  public var searchText: String?

  public init(
    limit: Int? = nil,
    before: String? = nil,
    dateRange: HarnessMonitorAuditDateRange? = nil,
    sources: [String] = [],
    categories: [String] = [],
    severities: [String] = [],
    outcomes: [String] = [],
    actionKeys: [String] = [],
    subject: String? = nil,
    searchText: String? = nil
  ) {
    self.limit = limit
    self.before = before
    self.dateRange = dateRange
    self.sources = sources
    self.categories = categories
    self.severities = severities
    self.outcomes = outcomes
    self.actionKeys = actionKeys
    self.subject = subject
    self.searchText = searchText
  }
}

public struct HarnessMonitorAuditEventsResponse: Codable, Equatable, Sendable {
  public var events: [HarnessMonitorAuditEvent]
  public var nextCursor: String?
  public var hasOlder: Bool

  public init(
    events: [HarnessMonitorAuditEvent] = [],
    nextCursor: String? = nil,
    hasOlder: Bool = false
  ) {
    self.events = events
    self.nextCursor = nextCursor
    self.hasOlder = hasOlder
  }
}

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

extension HarnessMonitorAuditEvent {
  private static let notificationIDPrefix = "notification:"
  private static let supervisorIDPrefix = "supervisor:"
  private static let githubReviewActionIDPrefix = "github-review-action:"
  private static let legacyDaemonIDPrefix = "legacy-daemon:"

  public static func notification(_ entry: NotificationHistoryEntry) -> Self {
    Self(
      id: "\(notificationIDPrefix)\(entry.id)",
      recordedAt: entry.recordedAt,
      source: "notifications",
      category: "notification",
      kind: "notification.\(entry.source.rawValue)",
      severity: entry.severity.rawValue,
      outcome: entry.status.rawValue,
      title: entry.title ?? entry.source.label,
      summary: entry.message,
      subject: entry.decisionID ?? entry.requestIdentifier ?? entry.categoryIdentifier,
      actor: entry.source.label,
      actionKey: "notification.\(entry.source.rawValue)",
      payloadJSON: notificationPayload(entry)
    )
  }

  public static func supervisor(_ snapshot: SupervisorEventSnapshot) -> Self {
    let severity = snapshot.severityRaw ?? "info"
    let payload = jsonValue(fromJSONString: redactSupervisorPayloadJSON(snapshot.payloadJSON))
    return Self(
      id: "\(supervisorIDPrefix)\(snapshot.id)",
      recordedAt: snapshot.createdAt,
      source: "supervisor",
      category: "decision",
      kind: snapshot.kind,
      severity: severity,
      outcome: supervisorOutcome(kind: snapshot.kind),
      title: humanizedKind(snapshot.kind),
      summary: supervisorSummary(snapshot),
      subject: snapshot.ruleID ?? snapshot.tickID,
      actor: "Supervisor",
      correlationID: snapshot.tickID,
      actionKey: snapshot.kind,
      payloadJSON: payload
    )
  }

  static func githubReviewActionBackfillEvents(
    from storedValue: String,
    limit: Int
  ) -> [Self] {
    guard
      !storedValue.isEmpty,
      let data = storedValue.data(using: .utf8),
      let entries = try? JSONDecoder().decode(
        [String: DashboardReviewActionAuditBackfillEntry].self,
        from: data
      )
    else {
      return []
    }

    return entries
      .sorted { lhs, rhs in
        if lhs.value.recordedAt != rhs.value.recordedAt {
          return lhs.value.recordedAt > rhs.value.recordedAt
        }
        return lhs.key < rhs.key
      }
      .prefix(max(limit, 0))
      .map { pullRequestID, entry in
        githubReviewAction(entry, pullRequestID: pullRequestID)
      }
  }

  static func githubReviewAction(
    _ entry: DashboardReviewActionAuditBackfillEntry,
    pullRequestID: String
  ) -> Self {
    let actionKey = githubReviewActionKey(forTitle: entry.title)
    return Self(
      id: "\(githubReviewActionIDPrefix)\(pullRequestID):\(entry.id)",
      recordedAt: entry.recordedAt,
      source: "github",
      category: "githubMutation",
      kind: actionKey,
      severity: entry.outcome.auditSeverity,
      outcome: entry.outcome.auditOutcome,
      title: entry.title,
      summary: entry.summary,
      subject: pullRequestID,
      actor: "Harness Monitor",
      actionKey: actionKey,
      payloadJSON: githubReviewActionPayload(
        entry,
        pullRequestID: pullRequestID,
        actionKey: actionKey
      ),
      legacyMessage: githubReviewActionLegacyMessage(entry)
    )
  }

  public static func legacyDaemonLog(_ event: DaemonAuditEvent) -> Self {
    let recordedAt = parseDate(event.recordedAt) ?? .distantPast
    return Self(
      id: "\(legacyDaemonIDPrefix)\(stableLegacyDaemonID(event))",
      recordedAt: recordedAt,
      source: "daemon",
      category: "legacyDaemonLog",
      kind: "daemon.log.\(event.level)",
      severity: daemonSeverity(event.level),
      outcome: daemonOutcome(event.level),
      title: "Daemon \(event.level.uppercased())",
      summary: event.message,
      legacyMessage: event.message
    )
  }

  public static func merged(_ events: [Self]) -> [Self] {
    var byKey: [String: Self] = [:]
    for event in events {
      byKey[event.dedupeKey] = event
    }
    return byKey.values.sorted(by: auditEventSort)
  }

  public static func auditEventSort(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt > rhs.recordedAt
    }
    return lhs.id < rhs.id
  }

  public static func parseDate(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) {
      return date
    }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: raw)
  }

  public static func encodeDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func decodeDate<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
  ) throws -> Date {
    let raw = try container.decode(String.self, forKey: key)
    if let date = parseDate(raw) {
      return date
    }
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "Invalid ISO-8601 audit timestamp: \(raw)"
    )
  }

  private static func notificationPayload(_ entry: NotificationHistoryEntry) -> JSONValue {
    var payload: [String: JSONValue] = [
      "entry_id": .string(entry.id),
      "source": .string(entry.source.rawValue),
      "status": .string(entry.status.rawValue),
      "status_text": .string(entry.statusText),
      "repeat_count": .number(Double(entry.repeatCount)),
    ]
    if let title = entry.title {
      payload["title"] = .string(title)
    }
    if let subtitle = entry.subtitle {
      payload["subtitle"] = .string(subtitle)
    }
    if let requestIdentifier = entry.requestIdentifier {
      payload["request_identifier"] = .string(requestIdentifier)
    }
    if let decisionID = entry.decisionID {
      payload["decision_id"] = .string(decisionID)
    }
    if let details = entry.details {
      payload["details"] = .string(details.summary ?? details.disclosureLabel)
    }
    return .object(payload)
  }

  private static func jsonValue(fromJSONString raw: String) -> JSONValue? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static func githubReviewActionKey(forTitle title: String) -> String {
    let normalized = title.lowercased()
    if normalized.contains("approv") {
      return "reviews.approve"
    }
    if normalized.contains("merg") {
      return "reviews.merge"
    }
    if normalized.contains("rerun") {
      return "reviews.rerun_checks"
    }
    if normalized.contains("label") {
      return "reviews.label"
    }
    if normalized.contains("request") && normalized.contains("review") {
      return "reviews.request_review"
    }
    if normalized.contains("rebase") {
      return "reviews.comment"
    }
    if normalized.contains("auto policy") || normalized.contains("auto") {
      return "reviews.auto"
    }
    return "reviews.legacy_action"
  }

  private static func githubReviewActionPayload(
    _ entry: DashboardReviewActionAuditBackfillEntry,
    pullRequestID: String,
    actionKey: String
  ) -> JSONValue {
    .object([
      "action_key": .string(actionKey),
      "legacy_pull_request_id": .string(pullRequestID),
      "legacy_entry_id": .string(entry.id),
      "legacy_title": .string(entry.title),
      "legacy_outcome": .string(entry.outcome.rawValue),
      "messages": .array(entry.messages.map(JSONValue.string)),
    ])
  }

  private static func githubReviewActionLegacyMessage(
    _ entry: DashboardReviewActionAuditBackfillEntry
  ) -> String {
    if entry.messages.isEmpty {
      return entry.summary
    }
    return ([entry.summary] + entry.messages).joined(separator: "\n")
  }

  private static func supervisorOutcome(kind: String) -> String {
    switch SupervisorEvent.Kind(rawValue: kind) {
    case .actionFailed:
      "failure"
    case .actionSuppressed:
      "suppressed"
    case .actionDispatched, .actionExecuted:
      "success"
    case nil:
      "unknown"
    }
  }

  private static func supervisorSummary(_ snapshot: SupervisorEventSnapshot) -> String {
    if let ruleID = snapshot.ruleID {
      return "\(humanizedKind(snapshot.kind)) for \(ruleID)"
    }
    return "\(humanizedKind(snapshot.kind)) on tick \(snapshot.tickID)"
  }

  private static func humanizedKind(_ kind: String) -> String {
    var output = ""
    for scalar in kind.unicodeScalars {
      if CharacterSet.uppercaseLetters.contains(scalar), !output.isEmpty {
        output.append(" ")
      }
      output.append(String(scalar))
    }
    return String(output.prefix(1)).uppercased() + String(output.dropFirst())
  }

  private static func stableLegacyDaemonID(_ event: DaemonAuditEvent) -> String {
    [event.recordedAt, event.level, event.message]
      .joined(separator: "|")
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .prefix(160)
      .description
  }

  private static func daemonSeverity(_ level: String) -> String {
    switch level.lowercased() {
    case "error":
      "error"
    case "warn", "warning":
      "warning"
    case "debug", "trace":
      "debug"
    default:
      "info"
    }
  }

  private static func daemonOutcome(_ level: String) -> String {
    switch level.lowercased() {
    case "error":
      "failure"
    case "warn", "warning":
      "warning"
    default:
      "recorded"
    }
  }
}
