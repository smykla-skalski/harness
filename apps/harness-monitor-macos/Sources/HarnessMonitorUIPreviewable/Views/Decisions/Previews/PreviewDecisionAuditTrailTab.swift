import HarnessMonitorKit
import SwiftUI

#Preview("Decision Audit Trail — empty") {
  DecisionAuditTrailTab()
    .frame(width: 420, height: 320)
}

#Preview("Decision Audit Trail — populated") {
  let first = SupervisorEvent(
    id: "evt-1",
    tickID: "tick-1",
    kind: "observe",
    ruleID: "stuck-agent",
    severity: nil,
    payloadJSON: "{\"summary\":\"rule observed idle gap\"}"
  )
  first.createdAt = Date(timeIntervalSince1970: 10)
  let second = SupervisorEvent(
    id: "evt-2",
    tickID: "tick-2",
    kind: "dispatch",
    ruleID: "stuck-agent",
    severity: .needsUser,
    payloadJSON: "{\"target\":{\"agentID\":\"agent-7\"},\"action\":\"queueDecision\"}"
  )
  second.createdAt = Date(timeIntervalSince1970: 20)

  return DecisionAuditTrailTab(events: [first, second])
    .frame(width: 420, height: 320)
}
