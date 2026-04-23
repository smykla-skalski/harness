import HarnessMonitorKit
import SwiftUI

#Preview("Decision Detail — empty") {
  DecisionDetailView()
    .frame(width: 600, height: 480)
}

#Preview("Decision Detail — populated") {
  let contextJSON = """
    {
      "snapshotExcerpt": "agent=agent-7 idle=720s",
      "relatedTimeline": ["signal.sent: 12:01", "reminder.sent: 12:05"],
      "observerIssues": ["observer_idle_gap"],
      "recentActions": ["nudge.sent"]
    }
    """
  let suggestedActionsJSON = """
    [
      {"id":"accept","title":"Accept","kind":"custom","payloadJSON":"{}"},
      {"id":"snooze-1h","title":"Snooze 1h","kind":"snooze","payloadJSON":"{\\"duration\\":3600}"},
      {"id":"dismiss","title":"Dismiss","kind":"dismiss","payloadJSON":"{}"}
    ]
    """
  let dispatchPayloadJSON = """
    {
      "target": {"sessionID": "sess-1", "agentID": "agent-7", "taskID": "task-3"},
      "action": "queueDecision"
    }
    """
  let decision = Decision(
    id: "decision-preview",
    severity: .needsUser,
    ruleID: "stuck-agent",
    sessionID: "sess-1",
    agentID: "agent-7",
    taskID: "task-3",
    summary: "Agent has not acknowledged a critical signal.",
    contextJSON: contextJSON,
    suggestedActionsJSON: suggestedActionsJSON
  )
  decision.createdAt = Date().addingTimeInterval(-600)

  let first = SupervisorEvent(
    id: "evt-1",
    tickID: "tick-1",
    kind: "observe",
    ruleID: "stuck-agent",
    severity: nil,
    payloadJSON: "{\"summary\":\"rule observed idle gap\"}"
  )
  first.createdAt = Date().addingTimeInterval(-590)
  let second = SupervisorEvent(
    id: "evt-2",
    tickID: "tick-2",
    kind: "dispatch",
    ruleID: "stuck-agent",
    severity: .needsUser,
    payloadJSON: dispatchPayloadJSON
  )
  second.createdAt = Date().addingTimeInterval(-560)

  return DecisionDetailView(
    decision: decision,
    auditEvents: [first, second],
    liveTick: DecisionLiveTickSnapshot(
      lastSnapshotID: "snap-42",
      tickLatencyP50Ms: 118,
      tickLatencyP95Ms: 286,
      activeObserverCount: 3,
      quarantinedRuleIDs: ["stuck-agent"]
    )
  )
  .frame(width: 700, height: 640)
}
