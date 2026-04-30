import Foundation
import HarnessMonitorKit

struct SessionTimelineNodeBuilder {
  let sessionID: String
  let entries: [TimelineEntry]
  let decisions: [Decision]

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
    let timestamp = SessionTimelineTimestampParser.parse(entry.recordedAt) ?? .distantPast
    return SessionTimelineNode(
      identity: .entry(entry.entryId),
      kind: linkedDecision == nil ? .event : .linkedDecision,
      timestamp: timestamp,
      rawTimestamp: entry.recordedAt,
      sourceLabel: entry.kind,
      title: entry.summary,
      detail: entryDetail(for: entry),
      eventTone: SessionTimelineTone.eventTone(for: entry),
      decision: linkedDecision
    )
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
      title: decision.summary,
      detail: decisionDetail(for: decision),
      eventTone: nil,
      decision: decision
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
