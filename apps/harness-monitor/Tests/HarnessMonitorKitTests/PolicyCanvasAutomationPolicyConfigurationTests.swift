import Foundation
import Testing

@Suite("Policy canvas automation policy configuration")
struct PolicyCanvasAutomationPolicyConfigurationTests {
  @Test("Policy canvas top bar exposes automation policy configuration")
  func policyCanvasTopBarExposesAutomationPolicyConfiguration() throws {
    let topBarSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let viewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView.swift"
    )
    let sheetSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasAutomationPolicySheet.swift"
    )
    let inspectorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasInspectorAutomationViews.swift"
    )

    #expect(topBarSource.contains("Automation Policies"))
    #expect(topBarSource.contains("Enforce Canvas"))
    #expect(topBarSource.contains("Clear Canvas"))
    #expect(topBarSource.contains("configureAutomationPolicies"))
    #expect(topBarSource.contains("hasEnforcedCanvasPolicies"))
    #expect(topBarSource.contains("enforceCanvasPolicies"))
    #expect(
      !topBarSource.contains(".disabled(viewModel.automationPolicyCompilation.policies.isEmpty)")
    )
    #expect(viewSource.contains("PolicyCanvasAutomationPolicySheet()"))
    #expect(viewSource.contains("automationPolicyCenter.document.hasCanvasPolicies"))
    #expect(viewSource.contains("enforceCanvasAutomationPolicies"))
    #expect(sheetSource.contains("SettingsPoliciesSection(isActive: true)"))
    #expect(inspectorSource.contains("Compile policy"))
    #expect(inspectorSource.contains("Automation event source"))
    #expect(inspectorSource.contains("AutomationPolicyAction.allCases"))
  }

  @Test("Settings policy rules expose source app filters for all policy sources")
  func settingsPolicyRulesExposeSourceAppFiltersForAllPolicySources() throws {
    let rulesSource = try previewableSourceFile(
      named: "Views/Settings/SettingsAutomationPolicyRulesSection.swift"
    )

    #expect(rulesSource.contains("sourceApplicationFilters(policy)"))
    #expect(!rulesSource.contains("if policy.eventSource == .clipboard"))
    #expect(rulesSource.contains("filter source applications preprocessor"))
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
