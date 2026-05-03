import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Workspace window decision reload repair")
@MainActor
struct WorkspaceWindowDecisionReloadTests {
  @Test("Reload repair advances to the next visible decision after resolving the current one")
  func reloadRepairAdvancesToNextVisibleDecision() {
    let currentScope = scope(
      decisions: [
        makeDecision(id: "decision-1", createdAtOffset: 0),
        makeDecision(id: "decision-3", createdAtOffset: 2),
      ]
    )

    let repair = WorkspaceWindowView.repairedDecisionSelectionAfterReload(
      previousSelection: .decision(sessionID: "sess-workspace", decisionID: "decision-2"),
      previousVisibleDecisionIDs: ["decision-1", "decision-2", "decision-3"],
      requestedDecisionID: "decision-2",
      currentScope: currentScope,
      fallbackSessionID: "sess-workspace"
    )

    #expect(
      repair?.selection
        == .decision(sessionID: "sess-workspace", decisionID: "decision-3")
    )
    #expect(repair?.supervisorSelectedDecisionID == "decision-3")
  }

  @Test("Reload repair preserves a surviving external decision request")
  func reloadRepairPreservesSurvivingExternalDecisionRequest() {
    let requestedDecision = makeDecision(id: "decision-2", createdAtOffset: 2)
    let currentScope = scope(
      decisions: [requestedDecision]
    )

    let repair = WorkspaceWindowView.repairedDecisionSelectionAfterReload(
      previousSelection: .decision(sessionID: "sess-workspace", decisionID: "decision-1"),
      previousVisibleDecisionIDs: ["decision-1", "decision-2"],
      requestedDecisionID: requestedDecision.id,
      currentScope: currentScope,
      fallbackSessionID: "sess-workspace"
    )

    #expect(
      repair?.selection
        == .decision(sessionID: "sess-workspace", decisionID: requestedDecision.id)
    )
    #expect(repair?.supervisorSelectedDecisionID == requestedDecision.id)
  }

  @Test("Reload repair falls back to the previous visible decision when the last row resolves")
  func reloadRepairFallsBackToPreviousVisibleDecision() {
    let currentScope = scope(
      decisions: [
        makeDecision(id: "decision-1", createdAtOffset: 0)
      ]
    )

    let repair = WorkspaceWindowView.repairedDecisionSelectionAfterReload(
      previousSelection: .decision(sessionID: "sess-workspace", decisionID: "decision-2"),
      previousVisibleDecisionIDs: ["decision-1", "decision-2"],
      requestedDecisionID: "decision-2",
      currentScope: currentScope,
      fallbackSessionID: "sess-workspace"
    )

    #expect(
      repair?.selection
        == .decision(sessionID: "sess-workspace", decisionID: "decision-1")
    )
    #expect(repair?.supervisorSelectedDecisionID == "decision-1")
  }

  @Test("Reload repair returns to the decisions desk when no visible replacement remains")
  func reloadRepairReturnsToDecisionDeskWhenNoReplacementRemains() {
    let currentScope = scope(decisions: [])

    let repair = WorkspaceWindowView.repairedDecisionSelectionAfterReload(
      previousSelection: .decision(sessionID: "sess-workspace", decisionID: "decision-1"),
      previousVisibleDecisionIDs: ["decision-1"],
      requestedDecisionID: "decision-1",
      currentScope: currentScope,
      fallbackSessionID: "sess-workspace"
    )

    #expect(repair?.selection == .decisions(sessionID: "sess-workspace"))
    #expect(repair?.supervisorSelectedDecisionID == nil)
  }

  @Test("Reload repair clears a stale requested decision without changing the desk route")
  func reloadRepairClearsStaleRequestedDecisionOnDeskRoute() {
    let currentScope = scope(
      decisions: [
        makeDecision(id: "decision-1", createdAtOffset: 0)
      ]
    )

    let repair = WorkspaceWindowView.repairedDecisionSelectionAfterReload(
      previousSelection: .decisions(sessionID: "sess-workspace"),
      previousVisibleDecisionIDs: ["decision-2"],
      requestedDecisionID: "decision-2",
      currentScope: currentScope,
      fallbackSessionID: "sess-workspace"
    )

    #expect(repair?.selection == nil)
    #expect(repair?.supervisorSelectedDecisionID == nil)
  }

  @Test("Reconcile keeps the current detail route when an external request goes stale")
  func reconcileKeepsCurrentDetailRouteWhenExternalRequestGoesStale() {
    let currentDecision = makeDecision(id: "decision-1", createdAtOffset: 0)
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let view = WorkspaceWindowView(store: store)

    view.currentDecisionsRuntime.decisions = [currentDecision]
    view.refreshDecisionWorkspaceSnapshot()
    view.viewModel.selection = .decision(
      sessionID: currentDecision.sessionID,
      decisionID: currentDecision.id
    )
    store.supervisorSelectedDecisionID = "decision-stale"

    view.reconcileDecisionRouteAfterReload(
      previousSelection: view.viewModel.selection,
      previousVisibleDecisionIDs: [currentDecision.id],
      requestedDecisionID: "decision-stale"
    )

    #expect(
      view.viewModel.selection
        == .decision(sessionID: currentDecision.sessionID, decisionID: currentDecision.id)
    )
    #expect(store.supervisorSelectedDecisionID == currentDecision.id)
  }

  private func scope(decisions: [Decision]) -> DecisionWorkspaceScope {
    DecisionWorkspaceScope(
      decisions: decisions,
      filters: .init(query: "", severities: [], scope: .summary)
    )
  }

  private func makeDecision(
    id: String,
    createdAtOffset: TimeInterval
  ) -> Decision {
    let decision = Decision(
      id: id,
      severity: .critical,
      ruleID: "daemon-disconnect",
      sessionID: "sess-workspace",
      agentID: nil,
      taskID: nil,
      summary: "Workspace reload repair fixture for \(id).",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    decision.createdAt = Date(timeIntervalSince1970: createdAtOffset)
    return decision
  }
}
