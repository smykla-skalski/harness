import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Session decision runtime")
struct SessionDecisionRuntimeTests {
  @Test("Context rows omit detail-owned fields and keep orthogonal context")
  func contextRowsOmitDetailOwnedFieldsAndKeepOrthogonalContext() {
    let runtime = SessionDecisionRuntime()
    let rows = runtime.contextRows(
      for: makeDecision(
        contextJSON: #"""
          {
            "zone":"dev",
            "attempt":2,
            "status":"open",
            "ruleID":"stuck-agent",
            "agentID":"a1",
            "taskID":"t1",
            "summary":"Agent stalled"
          }
          """#
      )
    )

    #expect(rows.contains(.init(id: "session", value: "Session: s1")))
    #expect(rows.contains { $0.id == "context.zone" && $0.value == "zone: dev" })
    #expect(rows.contains { $0.id == "context.attempt" && $0.value == "attempt: 2" })
    #expect(!rows.contains { $0.id == "context.status" })
    #expect(!rows.contains { $0.id == "context.ruleID" })
    #expect(!rows.contains { $0.id == "context.agentID" })
    #expect(!rows.contains { $0.id == "context.taskID" })
    #expect(!rows.contains { $0.id == "context.summary" })
  }

  @Test("Context rows are empty when only detail-owned values remain")
  func contextRowsAreEmptyWhenOnlyDetailOwnedValuesRemain() {
    let rows = SessionDecisionRuntime().contextRows(
      for: makeDecision(
        sessionID: nil,
        contextJSON: #"""
          {"status":"open","ruleID":"stuck-agent","agentID":"a1","taskID":"t1"}
          """#
      )
    )

    #expect(rows.isEmpty)
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

  @Test("Filter key changes when filter query changes")
  func filterKeyChangesWhenFilterQueryChanges() {
    let firstFilters = SessionDecisionFilterState()
    let secondFilters = SessionDecisionFilterState()
    secondFilters.query = "Escalate"
    let decisions = [makeDecision(id: "d1", summary: "Escalate")]

    let firstKey = SessionDecisionFilterKey(
      sessionID: "s1",
      decisions: decisions,
      filters: firstFilters
    )
    let secondKey = SessionDecisionFilterKey(
      sessionID: "s1",
      decisions: decisions,
      filters: secondFilters
    )

    #expect(firstKey != secondKey)
  }

  @Test("Decision data key changes when decision searchable fields change")
  func decisionDataKeyChangesWhenDecisionSearchableFieldsChange() {
    let first = makeDecision(id: "d1", summary: "Old summary")
    let second = makeDecision(id: "d1", summary: "New summary")

    let firstKey = SessionDecisionDataKey(sessionID: "s1", decisions: [first])
    let secondKey = SessionDecisionDataKey(sessionID: "s1", decisions: [second])

    #expect(firstKey != secondKey)
  }

  @Test("Filter runtime emits apply signpost for the performance budget")
  func filterRuntimeEmitsApplySignpostForPerformanceBudget() throws {
    let source = try sourceFile(named: "SessionDecisionRuntime.swift")

    #expect(source.contains("OSSignposter"))
    #expect(source.contains("perf/session-decision-filter"))
    #expect(source.contains("session_decision_filter.apply"))
  }

  @Test("Audit payload presentations are cached alongside scoped audit events")
  func auditPayloadPresentationsAreCachedAlongsideScopedAuditEvents() throws {
    let source = try sourceFile(named: "SessionDecisionRuntime.swift")

    #expect(source.contains("private(set) var auditEventPayloadPresentations"))
    #expect(source.contains("guard auditEvents != scopedEvents else { return }"))
    #expect(source.contains("let decoder = JSONDecoder()"))
    #expect(
      source.contains(
        "DecisionAuditTrailPayloadPresentation(payloadJSON: $0.payloadJSON, decoder: decoder)"
      )
    )
  }

  private func makeDecision(
    id: String = "d1",
    severity: DecisionSeverity = .needsUser,
    summary: String = "Agent stalled",
    agentID: String? = "a1",
    sessionID: String? = "s1",
    contextJSON: String = "{}"
  ) -> Decision {
    Decision(
      id: id,
      severity: severity,
      ruleID: "stuck-agent",
      sessionID: sessionID,
      agentID: agentID,
      taskID: "t1",
      summary: summary,
      contextJSON: contextJSON,
      suggestedActionsJSON: "[]"
    )
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
