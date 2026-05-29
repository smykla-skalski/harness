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
    let workspaceSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )
    let minimapOverlaySource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasMinimapOverlay.swift"
    )

    #expect(settingsPoliciesSource.contains("Dashboard > Policies is the source of truth"))
    #expect(settingsPoliciesSource.contains("Open Policy Workspace"))
    #expect(settingsPoliciesSource.contains("Enable automation policies"))
    #expect(settingsPoliciesSource.contains("Show canvas minimap"))
    #expect(settingsPoliciesSource.contains("PolicyCanvasMinimapDefaults.isVisibleKey"))
    #expect(
      settingsPoliciesSource.contains("HarnessMonitorAccessibility.settingsPoliciesMinimapToggle"))
    #expect(settingsPoliciesSource.contains("Show shortcuts reference"))
    #expect(!settingsPoliciesSource.contains("Capture Current Clipboard"))
    // The workspace wires the minimap through the dedicated viewport overlay,
    // which reads the live viewport rect from its own observable so a scroll
    // does not re-evaluate the whole viewport body.
    #expect(workspaceSource.contains("PolicyCanvasMinimapViewportOverlay("))
    #expect(minimapOverlaySource.contains("snapshot.worldBounds"))
    #expect(minimapOverlaySource.contains("PolicyCanvasVisualStyle.canvasBackground"))
    #expect(minimapOverlaySource.contains("PolicyCanvasVisualStyle.primaryText.opacity("))
    #expect(menuBarSource.contains("Open Policy Workspace..."))
  }

  @Test("Policy canvas chrome and lab window expose a local theme override")
  func policyCanvasChromeAndLabWindowExposeALocalThemeOverride() throws {
    let topBarSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let labSource = try appSourceFile(named: "PolicyCanvasLabWindowView.swift")

    #expect(topBarSource.contains("@AppStorage(PolicyCanvasThemeDefaults.modeKey)"))
    #expect(topBarSource.contains("private var canvasThemeMode"))
    #expect(topBarSource.contains("Picker(\"Canvas theme\", selection: $canvasThemeMode)"))
    #expect(topBarSource.contains("PolicyCanvasThemeMode.allCases"))
    #expect(topBarSource.contains(".pickerStyle(.inline)"))

    #expect(labSource.contains("@AppStorage(PolicyCanvasThemeDefaults.modeKey)"))
    #expect(labSource.contains("private var canvasThemeMode"))
    #expect(labSource.contains("Picker(\"Canvas theme\", selection: $canvasThemeMode)"))
    #expect(labSource.contains("PolicyCanvasThemeMode.allCases"))
    #expect(labSource.contains("ToolbarItem"))
  }

  @Test("Policy canvas surfaces apply the canvas theme override without window-wide leakage")
  func policyCanvasSurfacesApplyTheCanvasThemeOverrideWithoutWindowWideLeakage() throws {
    let themeSource = try previewableSourceFile(named: "Theme/HarnessMonitorThemeMode.swift")
    let viewSource = try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasView.swift")
    let viewportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportSurface.swift"
    )
    let workspaceSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )
    let scrollCoordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )
    let labSource = try appSourceFile(named: "PolicyCanvasLabWindowView.swift")

    #expect(themeSource.contains("struct PolicyCanvasThemeScopeModifier"))
    #expect(themeSource.contains("transformEnvironment(\\.colorScheme)"))
    #expect(themeSource.contains("resolvedColorScheme("))
    #expect(!viewSource.contains(".policyCanvasThemeScope()"))
    #expect(!viewportSource.contains(".policyCanvasThemeScope()"))
    #expect(workspaceSource.contains(".policyCanvasThemeScope()"))
    #expect(scrollCoordinatorSource.contains("let resolvedCanvasColorScheme: ColorScheme?"))
    #expect(
      scrollCoordinatorSource.contains(
        "if let resolvedCanvasColorScheme = snapshot.resolvedCanvasColorScheme"
      )
    )
    #expect(!labSource.contains("private var resolvedCanvasThemeMode"))
    #expect(!labSource.contains("themeMode: .constant(resolvedCanvasThemeMode)"))
    #expect(visualStyleSource.contains("Color(nsColor: .windowBackgroundColor)"))
    #expect(visualStyleSource.contains("Color(nsColor: .textBackgroundColor)"))
    #expect(!visualStyleSource.contains("Color(red:"))
    #expect(!visualStyleSource.contains("Color.white"))
  }

  @Test("Policy canvas light palette preserves hierarchy without hardcoded colors")
  func policyCanvasLightPalettePreservesHierarchyWithoutHardcodedColors() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )
    let nodeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNodeLayer.swift"
    )
    let groupSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGroupViews.swift"
    )
    let edgeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeLayers.swift"
    )
    let minimapSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasMinimapOverlay.swift"
    )

    #expect(visualStyleSource.contains("Color(nsColor: .underPageBackgroundColor)"))
    #expect(visualStyleSource.contains("static func groupFill("))
    #expect(visualStyleSource.contains("static func groupStroke("))
    #expect(visualStyleSource.contains("static func groupTitleBackground("))
    #expect(visualStyleSource.contains("static func edgeLabelBackground("))
    #expect(visualStyleSource.contains("static func edgeStrokeOpacity("))
    #expect(visualStyleSource.contains("static func edgeArrowOpacity("))
    #expect(visualStyleSource.contains("static func minimapBackground("))
    #expect(visualStyleSource.contains("static func minimapNodeFill("))
    #expect(nodeSource.contains("@Environment(\\.colorScheme)"))
    // Node cards intentionally carry no drop shadow: a blurred `.shadow` forces
    // an offscreen rasterization pass per card, so it is removed from the
    // scroll/zoom hot path. Guard against any shadow modifier creeping back.
    #expect(!nodeSource.contains(".shadow("))
    #expect(groupSource.contains("@Environment(\\.colorScheme)"))
    #expect(groupSource.contains("PolicyCanvasVisualStyle.groupFill("))
    #expect(groupSource.contains("PolicyCanvasVisualStyle.groupStroke("))
    #expect(groupSource.contains("PolicyCanvasVisualStyle.groupTitleBackground("))
    #expect(edgeSource.contains("@Environment(\\.colorScheme)"))
    #expect(edgeSource.contains("PolicyCanvasVisualStyle.edgeStrokeOpacity("))
    #expect(edgeSource.contains("PolicyCanvasVisualStyle.edgeArrowOpacity("))
    #expect(edgeSource.contains("PolicyCanvasVisualStyle.edgeLabelBackground("))
    #expect(!edgeSource.contains("PolicyCanvasVisualStyle.canvasBackground.opacity(0.72)"))
    #expect(minimapSource.contains("@Environment(\\.colorScheme)"))
    #expect(minimapSource.contains("PolicyCanvasVisualStyle.minimapBackground("))
    #expect(minimapSource.contains("PolicyCanvasVisualStyle.minimapNodeFill("))
  }

  @Test("Policy canvas light palette keeps the canvas on a native window surface")
  func policyCanvasLightPaletteKeepsTheCanvasOnANativeWindowSurface() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift")
    let gridSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGridLayers.swift")

    #expect(
      visualStyleSource.contains(
        "static let canvasBackground = Color(nsColor: .windowBackgroundColor)"
      )
    )
    #expect(
      gridSource.contains(
        "NSColor.windowBackgroundColor.setFill()"
      )
    )
    #expect(
      !visualStyleSource.contains(
        "static let canvasBackground = Color(nsColor: .underPageBackgroundColor)"
      )
    )
    #expect(!gridSource.contains("NSColor.textBackgroundColor.setFill()"))
  }

  @Test("Policy canvas floating controls avoid backdrop-toned overlay fills")
  func policyCanvasFloatingControlsAvoidBackdropTonedOverlayFills() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )
    let zoomControlsSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasZoomControls.swift"
    )
    let edgeLegendSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeKindLegend.swift"
    )

    #expect(visualStyleSource.contains("static func floatingControlBackground("))
    #expect(zoomControlsSource.contains("PolicyCanvasVisualStyle.floatingControlBackground("))
    #expect(!zoomControlsSource.contains("PolicyCanvasVisualStyle.panelBackground.opacity(0.94)"))
    #expect(edgeLegendSource.contains("PolicyCanvasVisualStyle.floatingControlBackground("))
    #expect(!edgeLegendSource.contains("PolicyCanvasVisualStyle.panelBackground.opacity(0.94)"))
  }

  @Test("Policy canvas floating controls share the collapsed legend height")
  func policyCanvasFloatingControlsShareTheCollapsedLegendHeight() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )
    let zoomControlsSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasZoomControls.swift"
    )
    let edgeLegendSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeKindLegend.swift"
    )

    #expect(visualStyleSource.contains("static let floatingControlMinHeight: CGFloat = 32"))
    #expect(
      zoomControlsSource.contains(
        ".frame(minHeight: PolicyCanvasVisualStyle.floatingControlMinHeight)"))
    #expect(
      edgeLegendSource.contains(
        ".frame(minHeight: PolicyCanvasVisualStyle.floatingControlMinHeight)"))
  }

  @Test("Policy canvas floating controls keep visible borders on light surfaces")
  func policyCanvasFloatingControlsKeepVisibleBordersOnLightSurfaces() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )
    let zoomControlsSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasZoomControls.swift"
    )
    let edgeLegendSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeKindLegend.swift"
    )

    #expect(visualStyleSource.contains("static func floatingControlBorder("))
    #expect(zoomControlsSource.contains("PolicyCanvasVisualStyle.floatingControlBorder("))
    #expect(!zoomControlsSource.contains(".stroke(PolicyCanvasVisualStyle.border, lineWidth: 1)"))
    #expect(edgeLegendSource.contains("PolicyCanvasVisualStyle.floatingControlBorder("))
    #expect(!edgeLegendSource.contains(".stroke(PolicyCanvasVisualStyle.border, lineWidth: 1)"))
  }

  @Test("Policy canvas light palette softens accent borders on light surfaces")
  func policyCanvasLightPaletteSoftensAccentBordersOnLightSurfaces() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )
    let nodeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNodeLayer.swift"
    )
    let groupSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGroupViews.swift"
    )

    #expect(visualStyleSource.contains("static func nodeStroke("))
    #expect(
      visualStyleSource.contains(
        """
        case (.light, false, true):
              opacity = 0.44
        """
      )
    )
    #expect(nodeSource.contains("PolicyCanvasVisualStyle.nodeStroke("))
    #expect(groupSource.contains("group.tone.color.opacity(colorScheme == .dark ? 0.26 : 0.30)"))
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
