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

  @Test("Policy Canvas Lab synchronizes DB-backed policies before dispatching image paste")
  func policyCanvasLabSynchronizesDBBackedPoliciesBeforeImagePasteDispatch() throws {
    let labWindowSource = try harnessSourceFile(named: "App/PolicyCanvasLabSceneHost.swift")
    guard
      let syncRange = labWindowSource.range(of: ".dashboardAutomationPolicyRuntimeSync("),
      let pasteRange = labWindowSource.range(of: ".dashboardDebuggingOCRPasteCommand()")
    else {
      Issue.record("Policy Canvas Lab must install policy sync and image paste dispatch")
      return
    }

    #expect(labWindowSource.contains("workspace: liveSnapshot.workspace"))
    #expect(labWindowSource.contains("activeDocument: liveSnapshot.document"))
    #expect(syncRange.lowerBound < pasteRange.lowerBound)
  }
}
