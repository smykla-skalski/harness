import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard retained route activity")
struct DashboardRetainedRouteActivityTests {
  @Test("Hidden retained routes disable MCP element tracking")
  func hiddenRoutesDisableMCPTracking() throws {
    let source = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )

    #expect(source.contains("DashboardRetainedRouteMCPTracking(isVisible:"))
    #expect(source.contains("parentTrackingEnabled && isVisible"))
    #expect(source.contains("isRouteVisible: isAuditVisible"))
    #expect(source.contains("isRouteVisible: isDiagnosticsVisible"))
  }

  @Test("Task Board automatic work follows route visibility")
  func taskBoardAutomaticWorkFollowsRouteVisibility() throws {
    let dashboard = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let overview = try previewableSourceFile(
      domain: "TaskBoard",
      named: "TaskBoardOverviewView.swift"
    )
    let navigation = try previewableSourceFile(
      domain: "TaskBoard",
      named: "TaskBoardOverviewView+DashboardNavigation.swift"
    )
    let localRouting = try previewableSourceFile(
      domain: "TaskBoard",
      named: "TaskBoardLocalHostRoutingState.swift"
    )

    #expect(dashboard.contains("DashboardTaskBoardInboxRefreshTaskID"))
    #expect(dashboard.contains("guard isRouteVisible else { return }"))
    #expect(overview.contains("if isRouteVisible {\n        activeContent"))
    #expect(overview.contains("let presentationInput = synchronizedPresentationInput"))
    #expect(overview.contains(".task(id: presentationInput)"))
    #expect(overview.contains(".task(id: searchText)"))
    #expect(navigation.contains("let presentationInput: TaskBoardOverviewPresentationInput?"))
    #expect(localRouting.contains("localHostRoutingStateValue.suspend()"))
  }

  @Test("Agents retain detail state while automatic loads stop when hidden")
  func agentDetailAutomaticLoadsFollowRouteVisibility() throws {
    let route = try previewableSourceFile(
      domain: "Agents",
      named: "DashboardAgentsRouteView.swift"
    )
    let navigation = try previewableSourceFile(
      domain: "Agents",
      named: "DashboardAgentsRouteView+Navigation.swift"
    )
    let terminal = try previewableSourceFile(
      domain: "Agents",
      named: "DashboardTerminalAgentDetailView.swift"
    )
    let acp = try previewableSourceFile(
      domain: "Agents",
      named: "DashboardAcpAgentDetailView.swift"
    )
    let codex = try previewableSourceFile(
      domain: "Agents",
      named: "DashboardCodexAgentDetailView.swift"
    )

    #expect(route.contains("refreshesAutomatically && isRouteVisible"))
    #expect(route.contains("guard isRouteVisible else { return retainedDecisionResolution }"))
    #expect(route.contains("DashboardAgentsNavigationTaskID("))
    #expect(navigation.contains("guard isRouteVisible else { return }"))
    #expect(terminal.contains(".task(id: automaticMembershipLoadTaskID)"))
    #expect(terminal.contains(".task(id: automaticPollingTaskID)"))
    #expect(acp.contains(".task(id: automaticLoadTaskID)"))
    #expect(codex.contains(".task(id: automaticLoadTaskID)"))
  }

  @Test("Inactive auxiliary routes remove their observed child bodies")
  func inactiveAuxiliaryRoutesRemoveObservedChildren() throws {
    let audit = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardAuditRouteView.swift"
    )
    let diagnostics = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardDiagnosticsRouteView.swift"
    )
    let dashboardPolicy = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardPolicyCanvasRouteView.swift"
    )
    let policyCanvas = try previewableSourceFile(
      domain: "PolicyCanvas",
      named: "PolicyCanvasView.swift"
    )

    #expect(audit.contains("if isRouteVisible {\n      activeContent"))
    #expect(diagnostics.contains("if isRouteVisible {\n      activeContent"))
    #expect(dashboardPolicy.contains("if isRouteVisible {\n          DashboardPolicyCanvasFooterBar("))
    #expect(dashboardPolicy.contains("isActive: isRouteVisible"))
    #expect(policyCanvas.contains("if isActive {\n      activeContent"))
  }
}
