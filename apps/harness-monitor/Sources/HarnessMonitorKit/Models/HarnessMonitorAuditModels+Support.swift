import Foundation

extension HarnessMonitorAuditEvent {
  // `notificationIDPrefix` and `decodeDate` are also used by the primary
  // file's `notificationEntryID` and `init(from:)`, so they are internal rather
  // than private (private would be file-scoped to this companion).
  static let notificationIDPrefix = "notification:"
  private static let supervisorIDPrefix = "supervisor:"
  private static let githubReviewActionIDPrefix = "github-review-action:"

  public func clipboardJSONString(prettyPrinted: Bool = true) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    let data = try encoder.encode(self)
    guard let text = String(data: data, encoding: .utf8) else {
      throw HarnessMonitorAuditEventClipboardError.encodedJSONIsNotUTF8
    }
    return prettyPrinted ? Self.collapsePrettyPrintedEmptyArrays(in: text) : text
  }

  private static func collapsePrettyPrintedEmptyArrays(in text: String) -> String {
    let pattern = #"\[\n[ \t]*\n[ \t]*\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      preconditionFailure("Empty-array JSON formatting pattern must compile")
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: "[]"
    )
  }

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

    return
      entries
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

  static func decodeDate<Key: CodingKey>(
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

}
