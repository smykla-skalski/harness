import Foundation
import Testing

@Suite("Policy canvas automation policy configuration")
struct PolicyCanvasAutomationPolicyConfigurationTests {
  @Test("Footer menu exposes automation policy configuration")
  func footerMenuExposesAutomationPolicyConfiguration() throws {
    let topBarSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let footerComponentsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )
    let routeSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
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
    #expect(!topBarSource.contains("Sync Effective Canvases"))
    #expect(!topBarSource.contains("Clear Effective Canvases"))
    #expect(!topBarSource.contains("PolicyCanvasSimulationToggleButton"))
    #expect(!topBarSource.contains("policyCanvasSimulationToggle"))
    #expect(topBarSource.contains("PolicyCanvasMinimapDefaults.isVisibleKey"))
    #expect(topBarSource.contains("PolicyCanvasMinimapDefaults.centeringModeKey"))
    #expect(topBarSource.contains("Hide minimap"))
    #expect(topBarSource.contains("Show minimap"))
    #expect(topBarSource.contains("Menu(\"Minimap recenter\")"))
    #expect(topBarSource.contains("PolicyCanvasMinimapCenteringMode.allCases"))
    #expect(topBarSource.contains("minimapCenteringMode = mode"))
    #expect(
      !topBarSource.contains("Picker(\"Minimap recenter\", selection: $minimapCenteringMode)"))
    #expect(!topBarSource.contains("configureAutomationPolicies"))
    #expect(!topBarSource.contains("hasEnforcedCanvasPolicies"))
    #expect(!topBarSource.contains("enforceCanvasPolicies"))
    #expect(!topBarSource.contains("Label(\"Policy tools\", systemImage: \"ellipsis.circle\")"))
    #expect(footerComponentsSource.contains("policyCanvasToolsButton"))
    #expect(footerComponentsSource.contains("PolicyCanvasToolsMenuContent("))
    #expect(footerComponentsSource.contains("Image(systemName: \"gearshape\")"))
    #expect(footerComponentsSource.contains("Menu {"))
    #expect(footerComponentsSource.contains(".menuStyle(.button)"))
    #expect(footerComponentsSource.contains(".harnessNativeFormControl()"))
    #expect(
      footerComponentsSource.contains(
        "HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)"
      )
    )
    #expect(topBarSource.contains("Hide edge legend"))
    #expect(topBarSource.contains("Show shortcuts reference"))
    #expect(
      !topBarSource.contains(".disabled(viewModel.automationPolicyCompilation.policies.isEmpty)")
    )
    #expect(!viewSource.contains("PolicyCanvasAutomationPolicySheet(viewModel: viewModel)"))
    #expect(routeSource.contains("PolicyCanvasAutomationPolicySheet("))
    #expect(routeSource.contains("viewModel: policyCanvasViewModel"))
    #expect(routeSource.contains("automationStore: .automationCenterBridge()"))
    #expect(sheetSource.contains("Dashboard > Policies is the source of truth"))
    #expect(sheetSource.contains("viewModel.automationPolicyCompilation"))
    #expect(sheetSource.contains("Enable automation enforcement"))
    #expect(!sheetSource.contains("SettingsPoliciesSection(isActive: true)"))
    #expect(settingsPoliciesSource.contains("Open Policy Workspace"))
    #expect(settingsPoliciesSource.contains("openDashboardRoute(.policyCanvas)"))
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

  @Test("Policy canvas library rows start native drag sessions")
  func policyCanvasLibraryRowsStartNativeDragSessions() throws {
    let rowViewsSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasLibraryRowViews.swift"
    )
    let dragSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasPaletteDragSource.swift"
    )

    #expect(rowViewsSource.contains("PolicyCanvasPaletteDragSource("))
    #expect(rowViewsSource.contains("payload: viewModel.palettePayload(for: kind)"))
    #expect(rowViewsSource.contains("payload: viewModel.palettePayload(for: item)"))
    #expect(!rowViewsSource.contains(".onDrag {"))
    #expect(!rowViewsSource.contains(".draggable("))
    #expect(!rowViewsSource.contains("paletteItemProvider"))
    #expect(!rowViewsSource.contains(".onDragSessionUpdated"))
    #expect(!rowViewsSource.contains("DragSession"))
    #expect(!rowViewsSource.contains("NSCursor"))
    #expect(dragSource.contains("NSViewRepresentable"))
    #expect(dragSource.contains("NSDraggingSource"))
    #expect(dragSource.contains("override func mouseDragged"))
    #expect(dragSource.contains("beginDraggingSession(with: [draggingItem]"))
    #expect(dragSource.contains("policyCanvasAcceptedTextPasteboardTypes"))
  }

  @Test("Policy library pane keeps command drag rows with measured width")
  func policyLibraryPaneKeepsCommandDragRowsWithMeasuredWidth() throws {
    let layoutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift")
    let toolRailSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasToolRailViews.swift")
    let viewSource = try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasView.swift")
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift")
    let dashboardHostSurface = "static let dashboardHostBackground = Color.clear"

    #expect(!layoutSource.contains("SessionContentDetailSplitView"))
    #expect(!layoutSource.contains("componentLibraryWidth"))
    #expect(!viewSource.contains("componentLibraryWidth"))

    #expect(toolRailSource.contains("let paneWidth = Self.libraryPaneWidth(metrics: metrics)"))
    #expect(toolRailSource.contains("PolicyCanvasLibraryPaneWidth"))
    #expect(toolRailSource.contains("PolicyCanvasLibraryPaneTextWidths(rows: libraryRows)"))
    #expect(!toolRailSource.contains(".fixedSize(horizontal: true"))

    #expect(toolRailSource.contains("ScrollView {"))
    #expect(toolRailSource.contains("ForEach(Self.libraryRows)"))
    #expect(toolRailSource.contains("A native List owns row gesture arbitration"))
    #expect(toolRailSource.contains(".padding(EdgeInsets("))
    #expect(!toolRailSource.contains("List(Self.libraryRows)"))
    #expect(!toolRailSource.contains(".listStyle(.plain)"))
    #expect(!toolRailSource.contains(".scrollContentBackground(.hidden)"))
    #expect(!toolRailSource.contains(".listRowInsets("))
    #expect(!toolRailSource.contains("LazyVStack"))
    #expect(visualStyleSource.contains(dashboardHostSurface))
    #expect(toolRailSource.contains(".background(PolicyCanvasVisualStyle.dashboardHostBackground)"))
    #expect(!toolRailSource.contains(".background(PolicyCanvasVisualStyle.railBackground)"))
    #expect(!toolRailSource.contains(".background(PolicyCanvasVisualStyle.panelBackground)"))
  }

  @Test("Settings policies section hands off to the policy workspace")
  func settingsPoliciesSectionHandsOffToPolicyWorkspace() throws {
    let settingsPoliciesSource = try previewableSourceFile(
      named: "Views/Settings/SettingsPoliciesSection.swift"
    )
    let menuBarSource = try appSourceFile(named: "HarnessMonitorMenuBarExtra.swift")
    let hostedContentSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+HostedContent.swift"
    )
    let viewportOverlaySource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportOverlayModifier.swift"
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
    // The viewport hosted content wires the minimap through the dedicated
    // viewport overlay, which reads the live viewport rect from its own
    // observable so a scroll does not re-evaluate the whole viewport body.
    #expect(hostedContentSource.contains("PolicyCanvasViewportOverlayModifier("))
    #expect(viewportOverlaySource.contains("PolicyCanvasMinimapViewportOverlay("))
    #expect(minimapOverlaySource.contains("snapshot.worldBounds"))
    #expect(minimapOverlaySource.contains("PolicyCanvasVisualStyle.canvasBackground"))
    #expect(minimapOverlaySource.contains("PolicyCanvasVisualStyle.primaryText.opacity("))
    #expect(menuBarSource.contains("Open Policy Workspace..."))
  }

  @Test("Settings policies section exposes minimap centering mode")
  func settingsPoliciesSectionExposesMinimapCenteringMode() throws {
    let settingsPoliciesSource = try previewableSourceFile(
      named: "Views/Settings/SettingsPoliciesSection.swift"
    )

    #expect(settingsPoliciesSource.contains("Minimap recenter"))
    #expect(settingsPoliciesSource.contains("PolicyCanvasMinimapDefaults.centeringModeKey"))
    #expect(settingsPoliciesSource.contains("PolicyCanvasMinimapCenteringMode.allCases"))
    #expect(
      settingsPoliciesSource.contains(
        "HarnessMonitorAccessibility.settingsPoliciesMinimapCenteringPicker"))
  }

  @Test("Policy canvas chrome and lab window expose a local theme override")
  func policyCanvasChromeAndLabWindowExposeALocalThemeOverride() throws {
    let topBarSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let labSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let labToolbarSource = try policyCanvasSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    #expect(topBarSource.contains("@AppStorage(PolicyCanvasThemeDefaults.modeKey)"))
    #expect(topBarSource.contains("private var canvasThemeMode"))
    #expect(topBarSource.contains("Menu(\"Canvas theme\")"))
    #expect(topBarSource.contains("themeMenuLabel(for: mode)"))
    #expect(topBarSource.contains(".accessibilityLabel(\"Canvas theme\")"))

    #expect(
      labSource.contains(
        "@AppStorage(PolicyCanvasLabThemeDefaults.modeKey)"
      )
    )
    #expect(
      labSource.contains(
        "private var windowThemeMode = PolicyCanvasLabThemeMode.defaultValue"
      )
    )
    #expect(labToolbarSource.contains("Picker(\"Window theme\", selection: $windowThemeMode)"))
    #expect(labToolbarSource.contains("PolicyCanvasLabThemeMode.allCases"))
    #expect(labSource.contains("ToolbarItem"))
  }

  @Test("Policy canvas surfaces apply the canvas theme override without window-wide leakage")
  func policyCanvasSurfacesApplyTheCanvasThemeOverrideWithoutWindowWideLeakage() throws {
    let themeSource = try policyCanvasSourceFile(named: "PolicyCanvasThemeSupport.swift")
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
    let hostedRootSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator+HostedRoot.swift"
    )
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )
    let labSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    #expect(themeSource.contains("struct PolicyCanvasThemeScopeModifier"))
    #expect(themeSource.contains("struct PolicyCanvasResolvedThemeScopeModifier"))
    #expect(themeSource.contains("transformEnvironment(\\.colorScheme)"))
    #expect(themeSource.contains("resolvedColorScheme("))
    #expect(themeSource.contains("func policyCanvasResolvedThemeScope("))
    #expect(!viewSource.contains(".policyCanvasThemeScope()"))
    #expect(!viewportSource.contains(".policyCanvasThemeScope()"))
    #expect(!workspaceSource.contains(".policyCanvasThemeScope()"))
    #expect(scrollCoordinatorSource.contains("let resolvedCanvasColorScheme: ColorScheme?"))
    #expect(hostedRootSource.contains(".policyCanvasResolvedThemeScope("))
    #expect(!scrollCoordinatorSource.contains("transformEnvironment(\\.colorScheme)"))
    #expect(!labSource.contains("private var resolvedCanvasThemeMode"))
    #expect(!labSource.contains("themeMode: .constant(resolvedCanvasThemeMode)"))
    #expect(visualStyleSource.contains("Color(nsColor: .windowBackgroundColor)"))
    #expect(visualStyleSource.contains("Color(nsColor: .textBackgroundColor)"))
    #expect(!visualStyleSource.contains("Color(red:"))
    #expect(!visualStyleSource.contains("Color.white"))
  }

  @Test("Policy canvas host defers background chrome to the dashboard surface")
  func policyCanvasHostDefersBackgroundChromeToTheDashboardSurface() throws {
    let viewSource = try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasView.swift")
    let viewportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportSurface.swift"
    )
    let routeSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift")

    #expect(!viewSource.contains(".background(PolicyCanvasVisualStyle.rootBackground)"))
    #expect(!viewportSource.contains(".background(PolicyCanvasVisualStyle.rootBackground)"))
    #expect(!routeSource.contains(".background(Color(nsColor: .windowBackgroundColor))"))
  }

  @Test("Policy canvas custom background is scoped to the document rect")
  func policyCanvasCustomBackgroundIsScopedToTheDocumentRect() throws {
    let viewportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )
    let hostedRootSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator+HostedRoot.swift"
    )

    #expect(!viewportSource.contains(".background(PolicyCanvasVisualStyle.canvasBackground)"))
    #expect(hostedRootSource.contains("PolicyCanvasBackgroundSurface()"))
    #expect(
      hostedRootSource.contains(".policyCanvasDocumentLayer(size: snapshot.contentSize)"))
    #expect(
      hostedRootSource.contains(
        ".offset(x: workspaceLayout.contentOrigin.x, y: workspaceLayout.contentOrigin.y)"
      ))
  }

  @Test("Policy local panels keep their native panel background")
  func policyLocalPanelsKeepTheirNativePanelBackground() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift"
    )

    #expect(
      visualStyleSource.contains(
        "static let panelBackground = Color(nsColor: .windowBackgroundColor)"
      )
    )
    #expect(
      !visualStyleSource.contains(
        "static let panelBackground = Color(nsColor: .underPageBackgroundColor)"
      )
    )
  }

  @Test("Policy canvas empty-state callout keeps its own local surface")
  func policyCanvasEmptyStateCalloutKeepsItsOwnLocalSurface() throws {
    let emptyStateSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEmptyStateView.swift"
    )

    #expect(!emptyStateSource.contains("PolicyCanvasVisualStyle.panelBackground.opacity(0.82)"))
    #expect(emptyStateSource.contains("PolicyCanvasVisualStyle.controlSurface"))
  }

  func previewableSourceFile(named relativePath: String) throws -> String {
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

  func appSourceFile(named fileName: String) throws -> String {
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

  func policyCanvasSourceFile(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorPolicyCanvas")
      .appendingPathComponent(fileName)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
