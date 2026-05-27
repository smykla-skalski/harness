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
    let layoutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift"
    )
    let sheetSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasAutomationPolicySheet.swift"
    )
    let inspectorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasInspectorAutomationViews.swift"
    )
    let paletteItemSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasAutomationPaletteItem.swift"
    )
    let toolRailSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasToolRailViews.swift"
    )
    let rowViewsSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasLibraryRowViews.swift"
    )
    let contributionsSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasAutomationPolicyContributions.swift"
    )
    let settingsPoliciesSource = try previewableSourceFile(
      named: "Views/Settings/SettingsPoliciesSection.swift"
    )

    #expect(topBarSource.contains("Automation Coverage"))
    #expect(topBarSource.contains("Enforce Canvas"))
    #expect(topBarSource.contains("Clear Canvas"))
    #expect(topBarSource.contains("configureAutomationPolicies"))
    #expect(topBarSource.contains("hasEnforcedCanvasPolicies"))
    #expect(topBarSource.contains("enforceCanvasPolicies"))
    #expect(topBarSource.contains("policyCanvasToolsButton"))
    #expect(topBarSource.contains("Menu {"))
    #expect(topBarSource.contains(".menuStyle(.button)"))
    #expect(topBarSource.contains(".harnessNativeFormControl()"))
    #expect(
      topBarSource.contains(
        "HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)"
      )
    )
    #expect(topBarSource.contains("Hide edge legend"))
    #expect(topBarSource.contains("Show shortcuts reference"))
    #expect(
      !topBarSource.contains(".disabled(viewModel.automationPolicyCompilation.policies.isEmpty)")
    )
    #expect(viewSource.contains("PolicyCanvasAutomationPolicySheet(viewModel: viewModel)"))
    #expect(layoutSource.contains("automationPolicyCenter.document.hasCanvasPolicies"))
    #expect(layoutSource.contains("enforceCanvasAutomationPolicies"))
    #expect(sheetSource.contains("Dashboard > Policies is the source of truth"))
    #expect(sheetSource.contains("viewModel.automationPolicyCompilation"))
    #expect(sheetSource.contains("Enable automation enforcement"))
    #expect(!sheetSource.contains("SettingsPoliciesSection(isActive: true)"))
    #expect(settingsPoliciesSource.contains("Open Policy Workspace"))
    #expect(settingsPoliciesSource.contains("openDashboardRoute(.policyCanvas)"))
    #expect(!settingsPoliciesSource.contains("SettingsAutomationPolicyRulesSection("))
    #expect(inspectorSource.contains("Compile policy"))
    #expect(inspectorSource.contains("Contribute to connected policy"))
    #expect(inspectorSource.contains("Automation event source"))
    #expect(inspectorSource.contains("AutomationPolicyAction.allCases"))
    #expect(toolRailSource.contains("PolicyCanvasComponentLibraryPane"))
    #expect(toolRailSource.contains("PolicyCanvasAutomationPaletteItem.items"))
    #expect(rowViewsSource.contains("createAutomationNode("))
    #expect(!toolRailSource.contains("PolicyCanvasAutomationPaletteMenu"))
    #expect(paletteItemSource.contains("case clipboardMonitor"))
    #expect(paletteItemSource.contains("case sourceApplicationFilter"))
    #expect(paletteItemSource.contains("case ocrImages"))
    #expect(paletteItemSource.contains("case persistResult"))
    #expect(contributionsSource.contains("PolicyCanvasAutomationPolicyContribution"))
    #expect(contributionsSource.contains("selectedActions"))
  }

  @Test("Policy library pane is a non-resizable content-sized button stack")
  func policyLibraryPaneIsNonResizableButtonStack() throws {
    let layoutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift"
    )
    let toolRailSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasToolRailViews.swift"
    )
    let viewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView.swift"
    )

    // Non-resizable: the library pane no longer rides the shared resizable
    // split view or persists a draggable width.
    #expect(!layoutSource.contains("SessionContentDetailSplitView"))
    #expect(!layoutSource.contains("componentLibraryWidth"))
    #expect(!viewSource.contains("componentLibraryWidth"))

    // Sized to its content (font-scale aware via the rows), not a fixed column.
    #expect(toolRailSource.contains(".fixedSize(horizontal: true"))

    // Actions render as a plain scrollable button stack, not a List.
    #expect(!toolRailSource.contains("List("))
    #expect(toolRailSource.contains("ScrollView"))
  }

  @Test("Settings policies section hands off to the policy workspace")
  func settingsPoliciesSectionHandsOffToPolicyWorkspace() throws {
    let settingsPoliciesSource = try previewableSourceFile(
      named: "Views/Settings/SettingsPoliciesSection.swift"
    )
    let menuBarSource = try appSourceFile(named: "HarnessMonitorMenuBarExtra.swift")

    #expect(settingsPoliciesSource.contains("Dashboard > Policies is the source of truth"))
    #expect(settingsPoliciesSource.contains("Open Policy Workspace"))
    #expect(settingsPoliciesSource.contains("Enable automation policies"))
    #expect(settingsPoliciesSource.contains("Show shortcuts reference"))
    #expect(!settingsPoliciesSource.contains("Capture Current Clipboard"))
    #expect(menuBarSource.contains("Open Policy Workspace..."))
  }

  @Test("Settings policy rules expose source app filters for all policy sources")
  func settingsPolicyRulesExposeSourceAppFiltersForAllPolicySources() throws {
    let rulesSource = try previewableSourceFile(
      named: "Views/Settings/SettingsAutomationPolicyRulesSection.swift"
    )

    #expect(rulesSource.contains("sourceApplicationFilters(policy)"))
    #expect(!rulesSource.contains("if policy.eventSource == .clipboard"))
    #expect(rulesSource.contains("filter source applications"))
    #expect(rulesSource.contains("preprocessor is enabled"))
  }

  @Test("Policy canvas caches automation policy compilation off body reads")
  func policyCanvasCachesAutomationPolicyCompilationOffBodyReads() throws {
    let compilerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasAutomationPolicyCompiler.swift"
    )
    let viewModelSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewModel.swift"
    )
    let cacheSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewModel+ValidationCache.swift"
    )

    #expect(viewModelSource.contains("var cachedAutomationPolicyCompilation"))
    #expect(viewModelSource.contains("func refreshAutomationPolicyCompilation()"))
    #expect(cacheSource.contains("refreshAutomationPolicyCompilation()"))
    #expect(compilerSource.contains("cachedAutomationPolicyCompilation"))
    #expect(!compilerSource.contains("compile(nodes: nodes, edges: edges)"))
    #expect(compilerSource.contains("appendNodeText(node, to: &text)"))
    #expect(!compilerSource.contains("reachableNodes.map(nodeText).joined"))
    #expect(!compilerSource.contains("edges\n      .filter"))
    #expect(!compilerSource.contains(".map { \"\\($0.label) \\($0.condition)"))
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

  private func appSourceFile(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitor/App")
      .appendingPathComponent(fileName)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
