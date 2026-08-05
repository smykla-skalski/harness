import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorStoreNavigationTests {
  @Test("Dashboard target requests preserve exact back and forward destinations")
  func dashboardTargetRequestsPreserveHistoryDestinations() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)
    let decisionTarget = DashboardAgentNavigationTarget.decision(decisionID: "decision-1")
    let taskTarget = DashboardTaskBoardNavigationTarget.item(itemID: "item-1")

    history.requestDashboardAgent(decisionTarget)
    let decisionRequest = try #require(history.pendingDashboardAgentsRestoreRequest)
    history.finishDashboardRestoreRequest(decisionRequest.requestID)
    history.finishDashboardAgentsRestoreRequest(decisionRequest.requestID)

    history.requestDashboardTaskBoard(taskTarget)
    let taskRequest = try #require(history.pendingDashboardTaskBoardRestoreRequest)
    history.finishDashboardRestoreRequest(taskRequest.requestID)
    history.finishDashboardTaskBoardRestoreRequest(taskRequest.requestID)

    history.navigateBack()
    #expect(history.pendingDashboardAgentsRestoreRequest?.target == decisionTarget)

    let restoredDecision = try #require(history.pendingDashboardAgentsRestoreRequest)
    history.finishDashboardRestoreRequest(restoredDecision.requestID)
    history.finishDashboardAgentsRestoreRequest(restoredDecision.requestID)
    history.navigateForward()

    #expect(history.pendingDashboardTaskBoardRestoreRequest?.target == taskTarget)
  }

  @Test("Restoring generic Audit clears an exact retained target")
  func genericAuditHistoryCreatesResetRequest() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.requestDashboardRoute(.audit)
    let genericRequest = try #require(history.pendingDashboardAuditRestoreRequest)
    #expect(genericRequest.target == nil)
    history.finishDashboardRestoreRequest(genericRequest.requestID)
    history.finishDashboardAuditRestoreRequest(genericRequest.requestID)

    history.requestDashboardAudit(.auditEvent(eventID: "event-1"))
    history.navigateBack()

    #expect(history.pendingDashboardAuditRestoreRequest?.target == nil)
  }

  @Test("Manual route selection cancels incompatible exact restores")
  func manualRouteSelectionOverridesExactRestore() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.requestDashboardTaskBoard(.item(itemID: "item-1"))
    history.userSelectedDashboardRoute(.agents)

    #expect(history.pendingDashboardRestoreRequest == nil)
    #expect(history.pendingDashboardTaskBoardRestoreRequest == nil)
    #expect(history.dashboardSelection == .route(.agents))
  }

  @Test("Manual Audit selection resets a retained exact target")
  func manualAuditSelectionCreatesResetRequest() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.requestDashboardAudit(.auditEvent(eventID: "event-1"))
    history.userSelectedDashboardRoute(.agents)
    history.userSelectedDashboardRoute(.audit)

    #expect(history.pendingDashboardAuditRestoreRequest?.target == nil)
    #expect(history.dashboardSelection == .route(.audit))
  }
}
