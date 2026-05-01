import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Workspace window startup selection")
@MainActor
struct WorkspaceWindowStartupSelectionTests {
  @Test("Pending workspace selection wins over a stale supervisor-selected decision")
  func pendingWorkspaceSelectionWins() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = makeDecision(id: "decision-startup-1", sessionID: "sess-startup-1")
    store.supervisorOpenDecisions = [decision]
    store.supervisorSelectedDecisionID = decision.id
    store.requestWorkspaceSelection(.decisions(sessionID: decision.sessionID))

    let view = WorkspaceWindowView(store: store)
    view.resolveInitialWorkspaceSelection()

    #expect(view.viewModel.selection == .decisions(sessionID: decision.sessionID))
    #expect(store.consumePendingWorkspaceSelection() == nil)
  }

  @Test("Explicit decision requests still restore on startup")
  func explicitDecisionRequestRestoresOnStartup() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = makeDecision(id: "decision-startup-2", sessionID: "sess-startup-2")
    store.supervisorOpenDecisions = [decision]
    store.supervisorSelectedDecisionID = decision.id
    store.requestWorkspaceDecisionSelection(decisionID: decision.id)

    let view = WorkspaceWindowView(store: store)
    view.resolveInitialWorkspaceSelection()

    #expect(
      view.viewModel.selection
        == .decision(sessionID: decision.sessionID, decisionID: decision.id)
    )
  }

  @Test("Stale supervisor-selected decisions do not hijack manual workspace open")
  func staleSupervisorSelectedDecisionDoesNotHijackManualOpen() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = makeDecision(id: "decision-startup-3", sessionID: "sess-startup-3")
    store.supervisorOpenDecisions = [decision]
    store.supervisorSelectedDecisionID = decision.id

    let view = WorkspaceWindowView(store: store)
    view.resolveInitialWorkspaceSelection()

    #expect(view.viewModel.selection == .create)
  }

  private func makeDecision(id: String, sessionID: String) -> Decision {
    let decision = Decision(
      id: id,
      severity: .critical,
      ruleID: "daemon-disconnect",
      sessionID: sessionID,
      agentID: nil,
      taskID: nil,
      summary: "Workspace startup routing regression fixture.",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    decision.createdAt = .distantPast
    return decision
  }
}
