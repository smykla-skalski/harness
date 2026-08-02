import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard window route titles")
struct DashboardWindowRouteTitleTests {
  @Test("Agents route exposes accessible Dashboard navigation chrome")
  func agentsRouteUsesDashboardChrome() {
    #expect(DashboardWindowRoute.agents.rawValue == "agents")
    #expect(DashboardWindowRoute.agents.title == "Agents")
    #expect(DashboardWindowRoute.agents.systemImage == "person.2")
    #expect(DashboardWindowRoute.agents.navigationTitle == "Dashboard")
    #expect(DashboardWindowRoute.agents.navigationSubtitle == "Agents")
  }

  @Test("Policies route keeps its sidebar title and clears dashboard title chrome")
  func policiesRouteKeepsSidebarTitleAndClearsDashboardTitleChrome() {
    #expect(DashboardWindowRoute.policyCanvas.title == "Policies")
    #expect(DashboardWindowRoute.policyCanvas.navigationTitle.isEmpty)
    #expect(DashboardWindowRoute.policyCanvas.navigationSubtitle.isEmpty)
  }

  @Test("Audit route replaces the old Notifications dashboard route")
  func auditRouteReplacesNotifications() {
    #expect(DashboardWindowRoute.audit.rawValue == "audit")
    #expect(DashboardWindowRoute.audit.title == "Audit")
    #expect(DashboardWindowRoute.audit.systemImage == "list.bullet.rectangle.portrait")
    #expect(DashboardWindowRoute.audit.navigationTitle == "Dashboard")
    #expect(DashboardWindowRoute.audit.navigationSubtitle == "Audit")
    #expect(DashboardWindowRoute.restoredRoute(rawValue: "notifications") == .audit)
  }
}
