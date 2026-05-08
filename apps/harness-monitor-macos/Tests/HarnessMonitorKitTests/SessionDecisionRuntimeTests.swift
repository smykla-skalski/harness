import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Session decision runtime")
struct SessionDecisionRuntimeTests {
  @Test("Context rows include routing fields and flattened JSON")
  func contextRowsIncludeRoutingFieldsAndFlattenedJSON() {
    let runtime = SessionDecisionRuntime()
    let rows = runtime.contextRows(for: makeDecision(contextJSON: #"{"zone":"dev","attempt":2}"#))

    #expect(rows.contains(.init(id: "rule", value: "stuck-agent")))
    #expect(rows.contains(.init(id: "status", value: "open")))
    #expect(rows.contains(.init(id: "session", value: "s1")))
    #expect(rows.contains(.init(id: "agent", value: "a1")))
    #expect(rows.contains(.init(id: "task", value: "t1")))
    #expect(rows.contains { $0.id == "context.zone" && $0.value == "zone: dev" })
    #expect(rows.contains { $0.id == "context.attempt" && $0.value == "attempt: 2" })
  }

  @Test("History rows include status and optional resolution data")
  func historyRowsIncludeStatusAndResolutionData() {
    let decision = makeDecision()
    decision.resolutionJSON = #"{"outcome":"dismissed"}"#

    let rows = SessionDecisionRuntime().historyRows(for: decision)

    #expect(rows.contains { $0.id == "created" })
    #expect(rows.contains(.init(id: "status", title: "Status", value: "open")))
    #expect(
      rows.contains(
        .init(id: "resolution", title: "Resolution", value: #"{"outcome":"dismissed"}"#)
      )
    )
  }

  @Test("Inspector width threshold matches the session-window contract")
  func inspectorWidthThresholdMatchesContract() {
    let runtime = SessionDecisionRuntime()

    #expect(!runtime.allowsInspector(width: 1_099))
    #expect(runtime.allowsInspector(width: 1_100))
  }

  @Test("Filter worker returns matching IDs without moving Decision models off main actor")
  func filterWorkerReturnsMatchingIDsWithoutMovingDecisionModelsOffMainActor() async {
    let runtime = SessionDecisionRuntime()
    let decisions = [
      makeDecision(id: "d-low", severity: .warn, summary: "Low attention", agentID: "agent-b"),
      makeDecision(id: "d-high", severity: .critical, summary: "Escalate", agentID: "agent-a"),
      makeDecision(id: "d-info", severity: .info, summary: "FYI", agentID: "agent-a"),
    ]
    let filters = SessionDecisionFilterState()
    filters.scope = .agent
    filters.query = "agent-a"
    filters.severities = [.critical, .info]

    runtime.updateFilteredDecisions(
      input: SessionDecisionFilterInput(sessionID: "s1", decisions: decisions, filters: filters)
    )
    await runtime.waitForDecisionFilterIdle()

    #expect(runtime.filteredDecisionIDs == ["d-high", "d-info"])
    #expect(runtime.filteredDecisions(from: decisions).map(\.id) == ["d-high", "d-info"])
  }

  @Test("Filter key changes when decision searchable fields change")
  func filterKeyChangesWhenDecisionSearchableFieldsChange() {
    let filters = SessionDecisionFilterState()
    let first = makeDecision(id: "d1", summary: "Old summary")
    let second = makeDecision(id: "d1", summary: "New summary")

    let firstKey = SessionDecisionFilterKey(sessionID: "s1", decisions: [first], filters: filters)
    let secondKey = SessionDecisionFilterKey(sessionID: "s1", decisions: [second], filters: filters)

    #expect(firstKey != secondKey)
  }

  private func makeDecision(
    id: String = "d1",
    severity: DecisionSeverity = .needsUser,
    summary: String = "Agent stalled",
    agentID: String? = "a1",
    contextJSON: String = "{}"
  ) -> Decision {
    Decision(
      id: id,
      severity: severity,
      ruleID: "stuck-agent",
      sessionID: "s1",
      agentID: agentID,
      taskID: "t1",
      summary: summary,
      contextJSON: contextJSON,
      suggestedActionsJSON: "[]"
    )
  }
}
