import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Dashboard window synchronizes DB-backed enforced policies for global commands")
  func dashboardWindowSynchronizesDBBackedEnforcedPoliciesForGlobalCommands() throws {
    let dashboardWindowSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardWindowView.swift"
    )

    #expect(dashboardWindowSource.contains("dashboardAutomationPolicyRuntimeSync("))
  }
}
