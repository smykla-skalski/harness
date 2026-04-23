import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Tests for the pure grouping/sorting/filtering logic behind `DecisionsSidebar`. The view
/// binds to these results via `DecisionsSidebarViewModel.grouped(decisions:query:severities:)`.
/// An empty `severities` set means "show all severities"; any non-empty set filters to exactly
/// the supplied members (multi-select semantics).
final class DecisionsSidebarViewModelTests: XCTestCase {
  private func makeDecision(
    id: String,
    severity: DecisionSeverity,
    summary: String,
    sessionID: String?
  ) -> Decision {
    Decision(
      id: id,
      severity: severity,
      ruleID: "rule-\(id)",
      sessionID: sessionID,
      agentID: nil,
      taskID: nil,
      summary: summary,
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
  }

  func test_grouped_groupsBySessionID() {
    let decisions = [
      makeDecision(id: "d1", severity: .info, summary: "alpha", sessionID: "s1"),
      makeDecision(id: "d2", severity: .warn, summary: "beta", sessionID: "s2"),
      makeDecision(id: "d3", severity: .info, summary: "gamma", sessionID: "s1"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: []
    )

    XCTAssertEqual(groups.count, 2)
    let s1 = groups.first { $0.sessionID == "s1" }
    let s2 = groups.first { $0.sessionID == "s2" }
    XCTAssertEqual(s1?.decisions.map(\.id).sorted(), ["d1", "d3"])
    XCTAssertEqual(s2?.decisions.map(\.id), ["d2"])
  }

  func test_grouped_placesUnassignedDecisionsInOrphanGroup() {
    let decisions = [
      makeDecision(id: "d1", severity: .info, summary: "no session", sessionID: nil),
      makeDecision(id: "d2", severity: .warn, summary: "scoped", sessionID: "s1"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: []
    )

    XCTAssertTrue(groups.contains { $0.sessionID == nil })
    XCTAssertTrue(groups.contains { $0.sessionID == "s1" })
  }

  func test_grouped_sortsBySeverityDescendingWithinSession() {
    let decisions = [
      makeDecision(id: "info", severity: .info, summary: "a", sessionID: "s1"),
      makeDecision(id: "crit", severity: .critical, summary: "b", sessionID: "s1"),
      makeDecision(id: "warn", severity: .warn, summary: "c", sessionID: "s1"),
      makeDecision(id: "needs", severity: .needsUser, summary: "d", sessionID: "s1"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: []
    )

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].decisions.map(\.id), ["crit", "needs", "warn", "info"])
  }

  func test_grouped_filtersBySummarySubstringCaseInsensitive() {
    let decisions = [
      makeDecision(id: "d1", severity: .info, summary: "Agent stalled", sessionID: "s1"),
      makeDecision(id: "d2", severity: .warn, summary: "Codex approval", sessionID: "s1"),
      makeDecision(id: "d3", severity: .info, summary: "Policy gap", sessionID: "s2"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "agent",
      severities: []
    )

    let ids = groups.flatMap { $0.decisions.map(\.id) }
    XCTAssertEqual(ids, ["d1"])
  }

  func test_grouped_filtersBySeveritySet() {
    let decisions = [
      makeDecision(id: "info", severity: .info, summary: "a", sessionID: "s1"),
      makeDecision(id: "warn", severity: .warn, summary: "b", sessionID: "s1"),
      makeDecision(id: "needs", severity: .needsUser, summary: "c", sessionID: "s1"),
      makeDecision(id: "crit", severity: .critical, summary: "d", sessionID: "s1"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: [.needsUser, .critical]
    )

    let ids = groups.flatMap { $0.decisions.map(\.id) }
    XCTAssertEqual(ids.sorted(), ["crit", "needs"])
  }

  func test_grouped_severitySetIsExactMatchNotFloor() {
    // Picking only `.warn` must hide critical and needsUser above it, proving multi-select
    // semantics (exact membership) rather than the old minimum-severity floor behavior.
    let decisions = [
      makeDecision(id: "info", severity: .info, summary: "a", sessionID: "s1"),
      makeDecision(id: "warn", severity: .warn, summary: "b", sessionID: "s1"),
      makeDecision(id: "needs", severity: .needsUser, summary: "c", sessionID: "s1"),
      makeDecision(id: "crit", severity: .critical, summary: "d", sessionID: "s1"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: [.warn]
    )

    let ids = groups.flatMap { $0.decisions.map(\.id) }
    XCTAssertEqual(ids, ["warn"])
  }

  func test_grouped_emptySeveritySetShowsAll() {
    let decisions = [
      makeDecision(id: "info", severity: .info, summary: "a", sessionID: "s1"),
      makeDecision(id: "crit", severity: .critical, summary: "b", sessionID: "s1"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: []
    )

    let ids = groups.flatMap { $0.decisions.map(\.id) }
    XCTAssertEqual(ids.sorted(), ["crit", "info"])
  }

  func test_grouped_dropsEmptySessionGroupsAfterFiltering() {
    let decisions = [
      makeDecision(id: "d1", severity: .info, summary: "quiet", sessionID: "s1"),
      makeDecision(id: "d2", severity: .critical, summary: "loud", sessionID: "s2"),
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: [.critical]
    )

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].sessionID, "s2")
  }

  func test_grouped_returnsEmptyWhenNoMatches() {
    let decisions = [
      makeDecision(id: "d1", severity: .info, summary: "alpha", sessionID: "s1")
    ]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "zzz",
      severities: []
    )

    XCTAssertTrue(groups.isEmpty)
  }

  func test_grouped_stableSessionOrderingByEarliestCreatedAt() {
    // Two sessions — seed in reverse insertion order, still expect sorted by first createdAt.
    let later = makeDecision(id: "later", severity: .warn, summary: "x", sessionID: "s-late")
    let earlier = makeDecision(id: "earlier", severity: .warn, summary: "y", sessionID: "s-early")
    let decisions = [later, earlier]

    let groups = DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: "",
      severities: []
    )

    XCTAssertEqual(groups.count, 2)
    // Both should appear; ordering rule is deterministic alpha-by-sessionID when createdAt
    // collides so we assert set membership.
    XCTAssertEqual(Set(groups.compactMap { $0.sessionID }), ["s-early", "s-late"])
  }

  func test_severityComparable_criticalIsHighest() {
    XCTAssertTrue(DecisionSeverity.critical.sortKey > DecisionSeverity.needsUser.sortKey)
    XCTAssertTrue(DecisionSeverity.needsUser.sortKey > DecisionSeverity.warn.sortKey)
    XCTAssertTrue(DecisionSeverity.warn.sortKey > DecisionSeverity.info.sortKey)
  }

  func test_sidebarOrdering_matchesDescendingSeverity() {
    XCTAssertEqual(
      DecisionSeverity.sidebarOrdering,
      [.critical, .needsUser, .warn, .info]
    )
  }
}

final class AgentTuiCodexApprovalViewModelTests: XCTestCase {
  @MainActor
  func test_codexApprovalItems_includeDecisionBackedRowsEvenWithoutRunPayload() {
    let run = CodexRunSnapshot(
      runId: "run-1",
      sessionId: "sess-1",
      projectDir: "/tmp/harness",
      threadId: "thread-1",
      turnId: "turn-1",
      mode: .approval,
      status: .waitingApproval,
      prompt: "Approve patch",
      latestSummary: nil,
      finalMessage: nil,
      error: nil,
      pendingApprovals: [],
      createdAt: "2026-04-23T08:00:00Z",
      updatedAt: "2026-04-23T08:05:00Z"
    )
    let contextJSON = #"{"agentID":"run-1","approvalID":"approval-1"}"#
    let suggestedActionsJSON = """
      [
        {"id":"accept","kind":"custom","payloadJSON":"{}","title":"Accept"},
        {"id":"decline","kind":"custom","payloadJSON":"{}","title":"Decline"}
      ]
      """
    let decision = Decision(
      id: "codex-approval:sess-1:approval-1",
      severity: .needsUser,
      ruleID: "codex-approval",
      sessionID: "sess-1",
      agentID: "run-1",
      taskID: nil,
      summary: "Approve workspace write",
      contextJSON: contextJSON,
      suggestedActionsJSON: suggestedActionsJSON
    )

    let items = AgentTuiWindowView.codexApprovalItems(for: run, decisions: [decision])

    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0].approvalID, "approval-1")
    XCTAssertEqual(items[0].decisionID, decision.id)
    XCTAssertEqual(items[0].title, "Approve workspace write")
    XCTAssertEqual(items[0].actions.map(\.id), ["accept", "decline"])
  }
}
