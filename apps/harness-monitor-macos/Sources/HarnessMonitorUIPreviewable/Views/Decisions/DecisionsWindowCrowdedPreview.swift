import HarnessMonitorKit
import SwiftUI

private struct DecisionSpec {
  let id: String
  let severity: DecisionSeverity
  let ruleID: String
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let summary: String
  let ageSeconds: Int
}

private struct EventSpec {
  let id: String
  let tickID: String
  let kind: String
  let ruleID: String
  let severity: DecisionSeverity?
  let ageSeconds: Int
}

private let crowdedDecisionSpecs: [DecisionSpec] = [
  DecisionSpec(
    id: "dec-1",
    severity: .critical,
    ruleID: "runaway-agent",
    sessionID: "sess-alpha",
    agentID: "agent-01",
    taskID: "task-101",
    summary: "Agent spawned 47 shell invocations in 60s — possible loop.",
    ageSeconds: 45
  ),
  DecisionSpec(
    id: "dec-2",
    severity: .needsUser,
    ruleID: "stuck-agent",
    sessionID: "sess-alpha",
    agentID: "agent-02",
    taskID: "task-102",
    summary: "Agent idle for 12m awaiting clarification on deploy step.",
    ageSeconds: 120
  ),
  DecisionSpec(
    id: "dec-3",
    severity: .warn,
    ruleID: "flaky-check",
    sessionID: "sess-alpha",
    agentID: "agent-03",
    taskID: "task-103",
    summary: "Integration check oscillated green→red→green three times.",
    ageSeconds: 240
  ),
  DecisionSpec(
    id: "dec-4",
    severity: .info,
    ruleID: "coverage-drop",
    sessionID: "sess-alpha",
    agentID: "agent-03",
    taskID: "task-104",
    summary: "Test coverage dropped 1.4% after refactor.",
    ageSeconds: 300
  ),
  DecisionSpec(
    id: "dec-5",
    severity: .critical,
    ruleID: "secret-exposed",
    sessionID: "sess-beta",
    agentID: "agent-04",
    taskID: "task-201",
    summary: "AWS access key pattern detected in diff to main.rs.",
    ageSeconds: 60
  ),
  DecisionSpec(
    id: "dec-6",
    severity: .needsUser,
    ruleID: "merge-conflict",
    sessionID: "sess-beta",
    agentID: "agent-05",
    taskID: "task-202",
    summary: "Two agents edited the same file; manual reconcile needed.",
    ageSeconds: 180
  ),
  DecisionSpec(
    id: "dec-7",
    severity: .warn,
    ruleID: "slow-build",
    sessionID: "sess-beta",
    agentID: "agent-04",
    taskID: "task-203",
    summary: "Build time exceeded 4× rolling baseline (72s → 308s).",
    ageSeconds: 420
  ),
  DecisionSpec(
    id: "dec-8",
    severity: .info,
    ruleID: "lint-debt",
    sessionID: "sess-beta",
    agentID: "agent-06",
    taskID: "task-204",
    summary: "17 new clippy pedantic warnings introduced.",
    ageSeconds: 540
  ),
  DecisionSpec(
    id: "dec-9",
    severity: .info,
    ruleID: "dep-outdated",
    sessionID: "sess-beta",
    agentID: "agent-06",
    taskID: "task-205",
    summary: "tokio minor version behind workspace lock.",
    ageSeconds: 720
  ),
  DecisionSpec(
    id: "dec-10",
    severity: .critical,
    ruleID: "test-crash",
    sessionID: "sess-gamma",
    agentID: "agent-07",
    taskID: "task-301",
    summary: "HarnessMonitorUITests crashed in TableViewListCore_Mac2.",
    ageSeconds: 30
  ),
  DecisionSpec(
    id: "dec-11",
    severity: .needsUser,
    ruleID: "permission-denied",
    sessionID: "sess-gamma",
    agentID: "agent-08",
    taskID: "task-302",
    summary: "Sandbox blocked access to ~/.codex — approve?",
    ageSeconds: 90
  ),
  DecisionSpec(
    id: "dec-12",
    severity: .warn,
    ruleID: "memory-leak",
    sessionID: "sess-gamma",
    agentID: "agent-07",
    taskID: "task-303",
    summary: "Retain cycle suspected in DecisionsWindowRuntime snapshot.",
    ageSeconds: 480
  ),
  DecisionSpec(
    id: "dec-13",
    severity: .warn,
    ruleID: "rate-limit",
    sessionID: nil,
    agentID: "agent-09",
    taskID: nil,
    summary: "OpenAI 429 burst: 6 retries in 30s.",
    ageSeconds: 200
  ),
  DecisionSpec(
    id: "dec-14",
    severity: .info,
    ruleID: "housekeeping",
    sessionID: nil,
    agentID: nil,
    taskID: nil,
    summary: "Daily XDG state directory fingerprint rotated.",
    ageSeconds: 3_600
  ),
]

private let crowdedEventSpecs: [EventSpec] = [
  EventSpec(
    id: "evt-1",
    tickID: "t-120",
    kind: "observe",
    ruleID: "runaway-agent",
    severity: nil,
    ageSeconds: 46
  ),
  EventSpec(
    id: "evt-2",
    tickID: "t-120",
    kind: "dispatch",
    ruleID: "runaway-agent",
    severity: .critical,
    ageSeconds: 45
  ),
  EventSpec(
    id: "evt-3",
    tickID: "t-121",
    kind: "observe",
    ruleID: "stuck-agent",
    severity: nil,
    ageSeconds: 121
  ),
  EventSpec(
    id: "evt-4",
    tickID: "t-121",
    kind: "dispatch",
    ruleID: "stuck-agent",
    severity: .needsUser,
    ageSeconds: 120
  ),
  EventSpec(
    id: "evt-5",
    tickID: "t-122",
    kind: "observe",
    ruleID: "flaky-check",
    severity: nil,
    ageSeconds: 241
  ),
  EventSpec(
    id: "evt-6",
    tickID: "t-122",
    kind: "dispatch",
    ruleID: "flaky-check",
    severity: .warn,
    ageSeconds: 240
  ),
  EventSpec(
    id: "evt-7",
    tickID: "t-123",
    kind: "observe",
    ruleID: "secret-exposed",
    severity: nil,
    ageSeconds: 61
  ),
  EventSpec(
    id: "evt-8",
    tickID: "t-123",
    kind: "dispatch",
    ruleID: "secret-exposed",
    severity: .critical,
    ageSeconds: 60
  ),
  EventSpec(
    id: "evt-9",
    tickID: "t-124",
    kind: "quarantine",
    ruleID: "runaway-agent",
    severity: nil,
    ageSeconds: 40
  ),
  EventSpec(
    id: "evt-10",
    tickID: "t-125",
    kind: "observe",
    ruleID: "slow-build",
    severity: nil,
    ageSeconds: 421
  ),
  EventSpec(
    id: "evt-11",
    tickID: "t-125",
    kind: "dispatch",
    ruleID: "slow-build",
    severity: .warn,
    ageSeconds: 420
  ),
  EventSpec(
    id: "evt-12",
    tickID: "t-126",
    kind: "observe",
    ruleID: "memory-leak",
    severity: nil,
    ageSeconds: 481
  ),
  EventSpec(
    id: "evt-13",
    tickID: "t-126",
    kind: "dispatch",
    ruleID: "memory-leak",
    severity: .warn,
    ageSeconds: 480
  ),
  EventSpec(
    id: "evt-14",
    tickID: "t-127",
    kind: "ack",
    ruleID: "stuck-agent",
    severity: nil,
    ageSeconds: 110
  ),
  EventSpec(
    id: "evt-15",
    tickID: "t-128",
    kind: "dismiss",
    ruleID: "lint-debt",
    severity: nil,
    ageSeconds: 500
  ),
]

@MainActor
private func crowdedDecisions() -> [Decision] {
  let now = Date()
  let actionsJSON = """
    [
      {"id":"accept","title":"Accept","kind":"custom","payloadJSON":"{}"},
      {"id":"snooze-1h","title":"Snooze 1h","kind":"snooze","payloadJSON":"{\\"duration\\":3600}"},
      {"id":"dismiss","title":"Dismiss","kind":"dismiss","payloadJSON":"{}"}
    ]
    """
  return crowdedDecisionSpecs.map { spec in
    let contextJSON = #"{"snapshotExcerpt":"rule=\#(spec.ruleID) sev=\#(spec.severity.rawValue)"}"#
    let decision = Decision(
      id: spec.id,
      severity: spec.severity,
      ruleID: spec.ruleID,
      sessionID: spec.sessionID,
      agentID: spec.agentID,
      taskID: spec.taskID,
      summary: spec.summary,
      contextJSON: contextJSON,
      suggestedActionsJSON: actionsJSON
    )
    decision.createdAt = now.addingTimeInterval(-Double(spec.ageSeconds))
    return decision
  }
}

@MainActor
private func crowdedAuditEvents() -> [SupervisorEvent] {
  let now = Date()
  return crowdedEventSpecs.map { spec in
    let event = SupervisorEvent(
      id: spec.id,
      tickID: spec.tickID,
      kind: spec.kind,
      ruleID: spec.ruleID,
      severity: spec.severity,
      payloadJSON: #"{"summary":"\#(spec.kind) \#(spec.ruleID)"}"#
    )
    event.createdAt = now.addingTimeInterval(-Double(spec.ageSeconds))
    return event
  }
}

#Preview("Decisions Window — crowded") {
  @Previewable @State var selection: String? = "dec-5"
  let decisions = crowdedDecisions()
  let auditEvents = crowdedAuditEvents()
  let liveTick = DecisionLiveTickSnapshot(
    lastSnapshotID: "snap-8821",
    tickLatencyP50Ms: 94,
    tickLatencyP95Ms: 612,
    activeObserverCount: 12,
    quarantinedRuleIDs: ["runaway-agent", "test-crash", "secret-exposed"]
  )
  let selected = decisions.first(where: { $0.id == selection }) ?? decisions[0]

  NavigationSplitView {
    DecisionsSidebar(decisions: decisions, selection: $selection)
      .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
  } detail: {
    DecisionDetailView(
      decision: selected,
      auditEvents: auditEvents,
      liveTick: liveTick
    )
  }
  .navigationSplitViewStyle(.balanced)
  .frame(width: 1_200, height: 820)
}
