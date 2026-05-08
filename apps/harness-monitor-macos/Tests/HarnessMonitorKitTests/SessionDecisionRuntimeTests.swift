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

  private func makeDecision(contextJSON: String = "{}") -> Decision {
    Decision(
      id: "d1",
      severity: .needsUser,
      ruleID: "stuck-agent",
      sessionID: "s1",
      agentID: "a1",
      taskID: "t1",
      summary: "Agent stalled",
      contextJSON: contextJSON,
      suggestedActionsJSON: "[]"
    )
  }
}
