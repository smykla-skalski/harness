import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard window route titles")
struct DashboardWindowRouteTitleTests {
  @Test("Policies route keeps its sidebar title and clears dashboard title chrome")
  func policiesRouteKeepsSidebarTitleAndClearsDashboardTitleChrome() {
    #expect(DashboardWindowRoute.policyCanvas.title == "Policies")
    #expect(DashboardWindowRoute.policyCanvas.navigationTitle == "")
    #expect(DashboardWindowRoute.policyCanvas.navigationSubtitle == "")
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
