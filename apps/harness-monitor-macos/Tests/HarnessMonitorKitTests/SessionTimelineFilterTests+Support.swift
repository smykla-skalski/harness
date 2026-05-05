import Foundation

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineFilterState {
  init(
    query: String,
    searchScope: SessionTimelineSearchScope,
    tones: Set<SessionTimelineTone>,
    eventTypes: Set<String>,
    agents: Set<String>,
    tasks: Set<String>,
    decisionSeverities: Set<String>,
    semanticProperties: Set<SessionTimelineSemanticProperty>,
    rawPayloadKeys: Set<String>
  ) {
    self.init()
    self.query = query
    self.searchScope = searchScope
    self.tones = tones
    self.eventTypes = eventTypes
    self.agents = agents
    self.tasks = tasks
    self.decisionSeverities = decisionSeverities
    self.semanticProperties = semanticProperties
    self.rawPayloadKeys = rawPayloadKeys
  }
}

struct SessionTimelineDecisionFixture {
  var severity: DecisionSeverity = .warn
  var sessionID: String = "session-1"
  var agentID: String?
  var taskID: String?
  var actions: [SuggestedAction] = []
}

func makeDecision(
  id: String,
  fixture: SessionTimelineDecisionFixture = .init()
) -> Decision {
  let encodedActions =
    (try? JSONEncoder().encode(fixture.actions))
    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  let decision = Decision(
    id: id,
    severity: fixture.severity,
    ruleID: "policy.rule",
    sessionID: fixture.sessionID,
    agentID: fixture.agentID,
    taskID: fixture.taskID,
    summary: "Decision \(id)",
    contextJSON: "{}",
    suggestedActionsJSON: encodedActions
  )
  decision.createdAt = Date(timeIntervalSince1970: 1_900_000_010)
  return decision
}
