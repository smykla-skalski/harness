import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard window route titles")
struct DashboardWindowRouteTitleTests {
  @Test("Policies route keeps its dashboard title chrome")
  func policiesRouteKeepsItsDashboardTitleChrome() {
    #expect(DashboardWindowRoute.policyCanvas.title == "Policies")
    #expect(DashboardWindowRoute.policyCanvas.navigationTitle == "Policies")
    #expect(DashboardWindowRoute.policyCanvas.navigationSubtitle == "Project source of truth")
  }
}
