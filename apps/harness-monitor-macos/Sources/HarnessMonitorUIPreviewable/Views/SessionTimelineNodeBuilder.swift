import Foundation
import HarnessMonitorKit

struct SessionTimelineNodeBuilder {
  let sessionID: String
  let entries: [TimelineEntry]
  let decisions: [Decision]
  let context: TimelineFeatureContext

  init(
    sessionID: String,
    entries: [TimelineEntry],
    decisions: [Decision],
    context: TimelineFeatureContext = .empty
  ) {
    self.sessionID = sessionID
    self.entries = entries
    self.decisions = decisions
    self.context = context
  }

  /// Authoritative decision links are only `decisionID`, `decisionId`, or `decision_id`
  /// at the event payload top level or directly under `supervisor`. Nodes sort newest first,
  /// then Decision, Linked decision, Event, then stable id. Summary, task, agent, and rule
  /// context are intentionally forbidden as fallback action-matching heuristics.
  func build() -> [SessionTimelineNode] {
    let index = SessionTimelineDecisionIndex(decisions: decisions)
    var nodes = entries.map { entry in
      entryNode(for: entry, decisions: index.decisionsByID)
    }
    nodes += (index.decisionsBySessionID[sessionID] ?? []).map(Self.decisionNode)
    return nodes.sorted(by: Self.sortsBefore)
  }

  private func entryNode(
    for entry: TimelineEntry,
    decisions: [String: SessionTimelineDecisionSnapshot]
  ) -> SessionTimelineNode {
    let linkedDecision = Self.explicitDecisionID(in: entry.payload).flatMap { decisions[$0] }
    let toolCallMetadata = entry.toolCallTimelineEntryMetadata()
    let agentID = entry.agentId ?? toolCallMetadata?.agentID ?? toolCallMetadata?.acpAgentID
    let taskID = entry.taskId ?? linkedDecision?.taskID
    let timestamp = SessionTimelineTimestampParser.parse(entry.recordedAt) ?? .distantPast
    var node = SessionTimelineNode(
      identity: .entry(entry.entryId),
      kind: linkedDecision == nil ? .event : .linkedDecision,
      timestamp: timestamp,
      rawTimestamp: entry.recordedAt,
      sourceLabel: entry.kind,
      entryKind: entry.kind,
      title: entry.summary,
      detail: entryDetail(for: entry),
      agentID: agentID,
      taskID: taskID,
      eventTone: SessionTimelineTone.eventTone(for: entry),
      decision: linkedDecision,
      semanticProperties: Self.semanticProperties(
        for: entry,
        linkedDecision: linkedDecision,
        toolCallMetadata: toolCallMetadata,
        agentID: agentID,
        taskID: taskID
      ),
      rawPayloadKeys: Self.payloadPropertyKeys(in: entry.payload),
      toolCallMetadata: toolCallMetadata
    )
    if let feature = SessionTimelineEventFeatureRegistry.firstMatch(for: entry) {
      let patch = feature.patch(for: entry)
      node.tapTarget = patch.tapTarget
      node.eventTone = feature.tone(for: entry) ?? node.eventTone
      node.actions = feature.actions(for: node, ctx: context)
      node.contextMenuItems = feature.contextMenuItems(for: node, ctx: context)
      node.voiceOverLabelOverride = feature.voiceOverLabel(for: node, ctx: context)
      node.prefersCompactLayout = feature.prefersCompactLayout(for: node)
      node.statusBadgeLabel = feature.statusBadgeLabel(for: node, ctx: context)
    }
    return node
  }

  private static func decisionNode(
    for decision: SessionTimelineDecisionSnapshot
  ) -> SessionTimelineNode {
    SessionTimelineNode(
      identity: .decision(decision.id),
      kind: .decision,
      timestamp: decision.createdAt,
      rawTimestamp: nil,
      sourceLabel: decision.ruleID,
      entryKind: nil,
      title: decision.summary,
      detail: decisionDetail(for: decision),
      agentID: decision.agentID,
      taskID: decision.taskID,
      eventTone: nil,
      decision: decision,
      semanticProperties: semanticProperties(for: decision),
      rawPayloadKeys: []
    )
  }

  private func entryDetail(for entry: TimelineEntry) -> String? {
    if let taskID = entry.taskId {
      return "Task \(taskID)"
    }
    if let agentID = entry.agentId {
      return "Agent \(agentID)"
    }
    return nil
  }

  private static func decisionDetail(for decision: SessionTimelineDecisionSnapshot) -> String? {
    if let taskID = decision.taskID {
      return "Task \(taskID)"
    }
    if let agentID = decision.agentID {
      return "Agent \(agentID)"
    }
    return nil
  }

  static func explicitDecisionID(in payload: JSONValue) -> String? {
    guard case .object(let object) = payload else {
      return nil
    }
    if let decisionID = firstDecisionID(in: object) {
      return decisionID
    }
    guard case .object(let supervisor)? = object["supervisor"] else {
      return nil
    }
    return firstDecisionID(in: supervisor)
  }

  private static func firstDecisionID(in object: [String: JSONValue]) -> String? {
    for key in ["decisionID", "decisionId", "decision_id"] {
      guard case .string(let value)? = object[key] else {
        continue
      }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return nil
  }

  private static func semanticProperties(
    for entry: TimelineEntry,
    linkedDecision: SessionTimelineDecisionSnapshot?,
    toolCallMetadata: ToolCallTimelineEntryMetadata?,
    agentID: String?,
    taskID: String?
  ) -> Set<SessionTimelineSemanticProperty> {
    var properties: Set<SessionTimelineSemanticProperty> = []
    if linkedDecision != nil {
      properties.insert(.linkedDecision)
    }
    if toolCallMetadata != nil {
      properties.insert(.toolCall)
    }
    if agentID != nil {
      properties.insert(.agent)
    }
    if taskID != nil {
      properties.insert(.task)
    }
    if let toolCallMetadata, !toolCallMetadata.capabilityTags.isEmpty {
      properties.insert(.capabilityTags)
    }
    if let stopReason = toolCallMetadata?.stopReason,
      !stopReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      properties.insert(.stopReason)
    }
    if linkedDecision?.actions.isEmpty == false {
      properties.insert(.decisionAction)
    }
    return properties
  }

  private static func semanticProperties(
    for decision: SessionTimelineDecisionSnapshot
  ) -> Set<SessionTimelineSemanticProperty> {
    var properties: Set<SessionTimelineSemanticProperty> = []
    if decision.agentID != nil {
      properties.insert(.agent)
    }
    if decision.taskID != nil {
      properties.insert(.task)
    }
    if !decision.actions.isEmpty {
      properties.insert(.decisionAction)
    }
    return properties
  }

  // signal_sent / signal_acknowledged: signal_id at payload top level.
  // signal_received: signal_id under payload["event"].
  static func extractSignalID(from payload: JSONValue) -> String? {
    guard case .object(let object) = payload else { return nil }
    if case .string(let id)? = object["signal_id"], !id.isEmpty { return id }
    guard case .object(let event)? = object["event"],
      case .string(let id)? = event["signal_id"], !id.isEmpty
    else { return nil }
    return id
  }

  private static func payloadPropertyKeys(in payload: JSONValue) -> Set<String> {
    flattenPayloadKeys(in: payload, prefix: nil)
  }

  private static func flattenPayloadKeys(
    in payload: JSONValue,
    prefix: String?
  ) -> Set<String> {
    switch payload {
    case .object(let object):
      var keys: Set<String> = []
      for key in object.keys.sorted() {
        let path = prefix.map { "\($0).\(key)" } ?? key
        keys.insert(path)
        if let nestedValue = object[key] {
          keys.formUnion(flattenPayloadKeys(in: nestedValue, prefix: path))
        }
      }
      return keys
    case .array(let values):
      var keys: Set<String> = []
      if let prefix {
        keys.insert(prefix)
      }
      for value in values {
        keys.formUnion(flattenPayloadKeys(in: value, prefix: prefix))
      }
      return keys
    case .bool, .null, .number, .string:
      if let prefix {
        return [prefix]
      }
      return []
    }
  }

  private static func sortsBefore(_ lhs: SessionTimelineNode, _ rhs: SessionTimelineNode) -> Bool {
    if lhs.timestamp != rhs.timestamp {
      return lhs.timestamp > rhs.timestamp
    }
    if lhs.kind.sortPriority != rhs.kind.sortPriority {
      return lhs.kind.sortPriority < rhs.kind.sortPriority
    }
    return lhs.id < rhs.id
  }
}

private struct SessionTimelineDecisionIndex {
  let decisionsByID: [String: SessionTimelineDecisionSnapshot]
  let decisionsBySessionID: [String: [SessionTimelineDecisionSnapshot]]

  init(decisions: [Decision]) {
    let snapshots = decisions.map(SessionTimelineDecisionSnapshot.init(decision:))
    decisionsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
    let pairs = snapshots.compactMap { snapshot in
      snapshot.sessionID.map { (sessionID: $0, snapshot: snapshot) }
    }
    decisionsBySessionID = Dictionary(grouping: pairs, by: \.sessionID).mapValues { pairs in
      pairs.map(\.snapshot)
    }
  }
}

enum SessionTimelineTimestampParser {
  nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let internetDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let spaceSeparatedFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  static func parse(_ value: String) -> Date? {
    if let date = fractionalFormatter.date(from: value) {
      return date
    }

    if let date = internetDateFormatter.date(from: value) {
      return date
    }
    return spaceSeparatedFormatter.date(from: value)
  }
}
