import Foundation

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

enum MonitorTimelineSectionFixtures {
  static func makeTimelineEntry(
    entryID: String = "entry-1",
    recordedAt: String = "2026-04-30T12:00:00Z",
    kind: String = "signal_sent",
    agentID: String? = "agent-1",
    taskID: String? = nil,
    summary: String = "Timeline event",
    payload: JSONValue = .object([:])
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: entryID,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: "session-1",
      agentId: agentID,
      taskId: taskID,
      summary: summary,
      payload: payload
    )
  }

  static func makeDecision(
    id: String,
    severity: DecisionSeverity = .warn,
    ruleID: String = "rule.timeline",
    sessionID: String? = "session-1",
    agentID: String? = nil,
    taskID: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_775_000_000),
    suggestedActionsJSON: String = "[]"
  ) -> Decision {
    let decision = Decision(
      id: id,
      severity: severity,
      ruleID: ruleID,
      sessionID: sessionID,
      agentID: agentID,
      taskID: taskID,
      summary: "Decision \(id)",
      contextJSON: "{}",
      suggestedActionsJSON: suggestedActionsJSON
    )
    decision.createdAt = createdAt
    return decision
  }

  static func encoded(_ actions: [SuggestedAction]) -> String {
    let data = try? JSONEncoder().encode(actions)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }

  static func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  @MainActor
  static func makePresentation(
    sessionID: String,
    timeline: [TimelineEntry],
    isTimelineLoading: Bool
  ) -> SessionTimelineSectionPresentation {
    SessionTimelineSectionPresentation(
      sessionID: sessionID,
      timeline: timeline,
      timelineWindow: nil,
      decisions: [],
      signals: [],
      filters: .init(),
      isTimelineLoading: isTimelineLoading,
      dateTimeConfiguration: .default
    )
  }
}
