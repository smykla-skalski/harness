import Foundation
import XCTest

final class PolicyCanvasMultiCanvasSourceContractTests: XCTestCase {
  func testDashboardPolicyRouteOwnsSingleLiveEditor() throws {
    let dashboardRouteSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardRouteContent.swift"
    )
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardRouteSource.contains("DashboardPolicyCanvasRouteView("))
    XCTAssertTrue(dashboardPolicySource.contains("DashboardPolicyCanvasFooterBar("))
    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterTab("))
    XCTAssertTrue(dashboardPolicySource.contains("PolicyCanvasView("))
    XCTAssertFalse(dashboardPolicySource.contains("SessionPolicyCanvasRedirectView"))
    XCTAssertTrue(dashboardPolicySource.contains("SessionContentDetailSplitView("))
    XCTAssertTrue(dashboardPolicySource.contains("footer: {"))
    XCTAssertTrue(dashboardFooterSource.contains("ScrollView(.horizontal"))
    XCTAssertTrue(dashboardFooterSource.contains("dashboardPolicyCanvasFooterTabs"))
    XCTAssertTrue(dashboardPolicySource.contains(".task(id: refreshTaskID)"))
    XCTAssertTrue(dashboardPolicySource.contains("dashboardUI.connectionState"))
    XCTAssertFalse(dashboardPolicySource.contains("HSplitView {"))
  }

  func testDashboardPolicyRouteDefersLiveEditorStartupWork() throws {
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )

    XCTAssertTrue(
      dashboardPolicySource.contains(
        "@StateObject private var policyCanvasViewModelStore"
      )
    )
    XCTAssertTrue(
      dashboardPolicySource.contains(
        "StateObject(\n      wrappedValue: DashboardPolicyCanvasViewModelStore("
      )
    )
    XCTAssertFalse(
      dashboardPolicySource.contains("@State var policyCanvasViewModel: PolicyCanvasViewModel")
    )
    XCTAssertFalse(
      dashboardPolicySource.contains("_policyCanvasViewModel = State(")
    )
    XCTAssertFalse(
      dashboardPolicySource.contains(
        "State(\n      initialValue: PolicyCanvasViewModel.liveStartupState("
      )
    )
  }

  func testDashboardPolicyRouteUsesIntegratedFooterCanvasTabChrome() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let dashboardFooterChromeSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterTabChrome.swift"
    )

    let dashboardFooterComponentsSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains(".scrollIndicators(.hidden)"))
    XCTAssertTrue(
      dashboardFooterComponentsSource.contains("DashboardPolicyCanvasFooterTabButtonStyle(")
    )
    XCTAssertTrue(dashboardFooterComponentsSource.contains(".frame(maxHeight: .infinity)"))
    XCTAssertTrue(dashboardFooterChromeSource.contains(".overlay(alignment: .trailing)"))
    XCTAssertFalse(dashboardFooterSource.contains("NSCursor.pointingHand"))
    XCTAssertFalse(dashboardFooterSource.contains("NSCursor.pop()"))
    XCTAssertFalse(dashboardFooterSource.contains(".frame(height: 28)"))
    XCTAssertFalse(dashboardFooterSource.contains(".harnessPlainButtonStyle()"))
    XCTAssertFalse(dashboardFooterSource.contains("RoundedRectangle(cornerRadius: 6"))
    XCTAssertFalse(dashboardFooterSource.contains(".scrollContentBackground(.hidden)"))
    XCTAssertFalse(dashboardFooterSource.contains(".listStyle(.plain)"))
    XCTAssertFalse(dashboardFooterSource.contains(".listStyle(.sidebar)"))
  }

  func testDashboardPolicyFooterShowsDocumentFallbackInsteadOfBlankWorkspaceGap() throws {
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(
      dashboardPolicySource.contains("fallbackDocument: dashboardUI.taskBoardPolicyPipeline")
    )
    XCTAssertTrue(dashboardFooterSource.contains("fallbackActiveCanvasSummary"))
    XCTAssertFalse(dashboardFooterSource.contains("document.nodes.first?.title"))
    XCTAssertFalse(dashboardFooterSource.contains("Spacer(minLength: 0)"))
  }

  func testDashboardPolicyRouteAdoptsSaveWithoutReloadingLayout() throws {
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )

    XCTAssertTrue(
      dashboardPolicySource.contains(
        "let transaction = policyCanvasViewModel.beginDraftSaveTransaction()"
      )
    )
    XCTAssertTrue(dashboardPolicySource.contains("policyCanvasViewModel.finishDraftSaveTransaction("))
    XCTAssertTrue(dashboardPolicySource.contains("await store.savePolicyCanvasDraft("))
    XCTAssertFalse(dashboardPolicySource.contains("policyCanvasViewModel.draftSaveRequest("))
    XCTAssertFalse(dashboardPolicySource.contains("policyCanvasViewModel.adoptSuccessfulManualDraftSave("))
    XCTAssertFalse(dashboardPolicySource.contains("saveTaskBoardPolicyPipelineDraft("))
    XCTAssertFalse(dashboardPolicySource.contains("policyCanvasViewModel.documentGeneration"))
    XCTAssertFalse(dashboardPolicySource.contains("policyCanvasViewModel.resolveSuccessfulSave("))
    XCTAssertFalse(dashboardPolicySource.contains("policyCanvasViewModel.markManualSaveSucceeded()"))
    XCTAssertFalse(dashboardPolicySource.contains("policyCanvasViewModel.applyDocument("))
    XCTAssertTrue(dashboardPolicySource.contains("policyCanvasViewModel.applyPersistedDocument("))
  }

  func testDashboardPolicyRouteMovesCanvasMutationsIntoTabContextMenu() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains(".contextMenu {"))
    XCTAssertTrue(dashboardFooterSource.contains("duplicateCanvasFromTab(canvas)"))
    XCTAssertTrue(dashboardFooterSource.contains("renameCanvasFromTab(canvas)"))
    XCTAssertTrue(dashboardFooterSource.contains("deleteCanvasFromTab(canvas)"))
    XCTAssertFalse(dashboardFooterSource.contains("Button(\"Duplicate\", action: duplicateCanvas)"))
    XCTAssertFalse(dashboardFooterSource.contains("Button(\"Rename\", action: renameCanvas)"))
    XCTAssertFalse(
      dashboardFooterSource.contains("Button(\"Delete\", role: .destructive, action: deleteCanvas)")
    )
  }

  func testDashboardPolicyRouteUsesNeutralConsistentTabLabels() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    let dashboardFooterComponentsSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )

    XCTAssertTrue(dashboardFooterComponentsSource.contains(".font(.callout.weight(.medium))"))
    XCTAssertFalse(dashboardFooterSource.contains("Circle()"))
    XCTAssertFalse(dashboardFooterSource.contains("tabIndicatorSize"))
    XCTAssertFalse(
      dashboardFooterSource.contains(
        ".foregroundStyle(isSelected ? Color.accentColor : Color.primary)"
      )
    )
  }

  func testDashboardPolicyRouteIntegratesCreateCanvasControlIntoTabStrip() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    let dashboardFooterComponentsSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains("private var createCanvasTab: some View"))
    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterCreateTab("))
    XCTAssertTrue(dashboardFooterComponentsSource.contains("showsTrailingSeparator: false"))
    XCTAssertTrue(dashboardFooterComponentsSource.contains("Image(systemName: \"plus\")"))
    XCTAssertTrue(
      dashboardFooterSource.contains(".padding(.leading, HarnessMonitorTheme.spacingMD)")
    )
  }

  func testDashboardPolicyRouteMovesPolicyToolsIntoFooterCogMenu() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )
    let chromeSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )

    let dashboardFooterComponentsSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterToolsMenuButton("))
    XCTAssertTrue(dashboardFooterComponentsSource.contains("PolicyCanvasToolsMenuContent("))
    XCTAssertTrue(dashboardFooterComponentsSource.contains("Image(systemName: \"gearshape\")"))
    XCTAssertTrue(
      dashboardFooterComponentsSource.contains("HarnessMonitorAccessibility.policyCanvasToolsButton")
    )
    XCTAssertTrue(dashboardFooterComponentsSource.contains(".menuIndicator(.hidden)"))
    XCTAssertTrue(
      dashboardPolicySource.contains(
        "PolicyCanvasAutomationPolicySheet("
      )
    )
    XCTAssertTrue(dashboardPolicySource.contains("automationStore: .automationCenterBridge()"))
    XCTAssertFalse(chromeSource.contains("PolicyCanvasTopBarToolsMenu("))
    XCTAssertFalse(
      chromeSource.contains("Label(\"Policy tools\", systemImage: \"ellipsis.circle\")")
    )
  }

  func testDashboardPolicyRouteShowsSaveStatusBeforeFooterCogSection() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let workspaceSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )

    let dashboardFooterComponentsSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterSaveStatus("))
    XCTAssertTrue(dashboardFooterSource.contains("activity: policyCanvasViewModel.saveActivity"))
    XCTAssertTrue(
      dashboardFooterComponentsSource.contains("HarnessMonitorAccessibility.dashboardPolicyCanvasFooterSaveStatus")
    )
    XCTAssertTrue(
      dashboardFooterSource.contains(
        """
        DashboardPolicyCanvasFooterSaveStatus(
                  activity: policyCanvasViewModel.saveActivity
                )

                DashboardPolicyCanvasFooterToolsMenuButton(
        """
      )
    )
    XCTAssertFalse(workspaceSource.contains("PolicyCanvasSaveStatusPill(activity: viewModel.saveActivity)"))
  }

  func testPolicyCanvasChromeBannersDoNotAffectCanvasLayout() throws {
    let layoutSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift"
    )
    let viewSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasView.swift"
    )
    let chromeSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )

    XCTAssertTrue(layoutSource.contains("ZStack(alignment: .top) {"))
    XCTAssertTrue(layoutSource.contains("PolicyCanvasChromeBannerOverlay("))
    XCTAssertFalse(
      viewSource.contains(".inspector(isPresented:"),
      "Confidence content moved to an in-layout trailing pane; a native inspector promotes a third NavigationSplitView column that splits the toolbar and underlaps the sidebar."
    )
    XCTAssertTrue(
      viewSource.contains(
        "@AppStorage(\"policyCanvas.inspectorVisible\") private var policyCanvasInspectorVisibleState = true"
      )
    )
    XCTAssertFalse(layoutSource.contains("PolicyCanvasConfidencePanel("))
    XCTAssertFalse(layoutSource.contains("PolicyCanvasValidationPanel("))
    XCTAssertTrue(layoutSource.contains("policyCanvasViewportPane"))
    XCTAssertFalse(chromeSource.contains("if viewModel.hasPendingDocumentUpdate"))
    XCTAssertFalse(chromeSource.contains("PolicyCanvasAutosaveDisabledBanner("))
    XCTAssertFalse(chromeSource.contains("PolicyCanvasRecoveryBanner("))
  }

  func testPolicyCanvasConfidencePanelLivesInTrailingPane() throws {
    let layoutSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift"
    )
    let inspectorSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasConfidenceInspector.swift"
    )
    let matrixSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasDecisionMatrixView.swift"
    )

    XCTAssertFalse(
      layoutSource.contains("PolicyCanvasConfidencePanel("),
      "Confidence content should not take vertical space from the viewport."
    )
    XCTAssertTrue(layoutSource.contains("policyCanvasConfidencePane"))
    XCTAssertTrue(layoutSource.contains("if policyCanvasInspectorVisible"))
    XCTAssertTrue(inspectorSource.contains("PolicyCanvasConfidencePanel("))
    XCTAssertFalse(
      inspectorSource.contains("inspectorColumnWidth"),
      "The confidence pane is an in-layout column, not a native SwiftUI inspector."
    )
    XCTAssertTrue(inspectorSource.contains(".frame(width: 380)"))
    XCTAssertTrue(inspectorSource.contains("HarnessMonitorAccessibility.policyCanvasConfidencePanel"))
    let sidePaneFontBoostCount =
      layoutSource.components(separatedBy: ".policyCanvasPaneFontScaleBoost()").count - 1
    XCTAssertGreaterThanOrEqual(
      sidePaneFontBoostCount,
      2,
      "Both side panes (component library + confidence) nudge their base font size up so default text is not too small."
    )
    XCTAssertFalse(
      matrixSource.contains("min(CGFloat(rows.count) * 46, 220)"),
      "The decision list scrolls with the confidence pane; a fixed 220pt cap clipped rows while the pane had room."
    )
  }

  func testPolicyCanvasChromeBannersFollowCanvasThemeMode() throws {
    let bannerSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasBanners.swift"
    )

    XCTAssertTrue(bannerSource.contains(".policyCanvasThemeScope()"))
  }

  func testPolicyCanvasToolsMenuCanToggleAndHideMinimap() throws {
    let chromeSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let minimapSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasMinimapOverlay.swift"
    )

    XCTAssertTrue(chromeSource.contains("PolicyCanvasMinimapDefaults.isVisibleKey"))
    XCTAssertTrue(chromeSource.contains("PolicyCanvasMinimapDefaults.centeringModeKey"))
    XCTAssertTrue(chromeSource.contains("Hide minimap"))
    XCTAssertTrue(chromeSource.contains("Show minimap"))
    XCTAssertTrue(chromeSource.contains("Menu(\"Minimap recenter\")"))
    XCTAssertTrue(chromeSource.contains("PolicyCanvasMinimapCenteringMode.allCases"))
    XCTAssertTrue(chromeSource.contains("minimapCenteringMode = mode"))
    XCTAssertFalse(
      chromeSource.contains("Picker(\"Minimap recenter\", selection: $minimapCenteringMode)")
    )
    XCTAssertTrue(minimapSource.contains(".contextMenu"))
    XCTAssertTrue(minimapSource.contains("Hide minimap"))
    XCTAssertTrue(minimapSource.contains("PolicyCanvasMinimapDefaults.isVisibleKey"))
  }

  func testDashboardPolicyRouteUsesSelectedTintForAdjacentTabSeparators() throws {
    let dashboardFooterChromeSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterTabChrome.swift"
    )

    let dashboardFooterComponentsSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )

    XCTAssertTrue(dashboardFooterComponentsSource.contains("var showsLeadingSeparator = false"))
    XCTAssertTrue(dashboardFooterChromeSource.contains(".overlay(alignment: .leading)"))
    XCTAssertTrue(
      dashboardFooterComponentsSource.contains("dashboardPolicyCanvasFooterTabChrome(")
    )
    XCTAssertTrue(dashboardFooterChromeSource.contains("showsLeadingSeparator ? borderWidth : 0"))
    XCTAssertFalse(
      dashboardFooterChromeSource.contains(
        "return Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.34 : 0.24)"
      )
    )
  }

  func testDashboardPolicyRouteDoesNotMeasureFirstTabForLeadingFooterTint() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertFalse(dashboardFooterSource.contains("DashboardPolicyCanvasFooterFirstTabBoundsKey"))
    XCTAssertFalse(
      dashboardFooterSource.contains(
        ".anchorPreference(key: DashboardPolicyCanvasFooterFirstTabBoundsKey.self"
      )
    )
    XCTAssertFalse(
      dashboardFooterSource.contains(
        ".backgroundPreferenceValue(DashboardPolicyCanvasFooterFirstTabBoundsKey.self)"
      )
    )
  }

  func testDashboardPolicyRouteUsesOnlyPoliciesLoadingCopyInDetailPane() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )

    XCTAssertFalse(dashboardFooterSource.contains("Loading canvases"))
    XCTAssertFalse(dashboardFooterSource.contains("footerStatusStrip(\"Loading canvases\""))
    XCTAssertTrue(dashboardPolicySource.contains("\"Loading Policies\""))
    XCTAssertTrue(
      dashboardPolicySource.contains(
        "\"Policies will appear here once the workspace finishes loading.\""
      )
    )
    XCTAssertFalse(dashboardPolicySource.contains("\"Loading Policy Canvas\""))
    XCTAssertFalse(dashboardPolicySource.contains("\"Loading Policy Canvases\""))
    XCTAssertFalse(dashboardPolicySource.contains("\"The active policy canvas will appear here"))
  }

  func testDashboardPolicyRouteRefreshesMissingWorkspaceEvenWhenPipelineIsLoaded() throws {
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )

    XCTAssertTrue(dashboardPolicySource.contains("needsInitialRefresh: workspace == nil"))
    XCTAssertTrue(dashboardPolicySource.contains("if workspace == nil {"))
    XCTAssertFalse(
      dashboardPolicySource.contains(
        "needsInitialRefresh: workspace == nil && dashboardUI.taskBoardPolicyPipeline == nil"
      )
    )
    XCTAssertFalse(
      dashboardPolicySource.contains(
        "if workspace == nil && dashboardUI.taskBoardPolicyPipeline == nil {"
      )
    )
  }

  func testDashboardPolicyRouteUsesInlineFooterCanvasRename() throws {
    let dashboardRouteSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let dashboardFooterComponentsSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterComponents.swift"
    )
    let tabEditorSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterTabTitleEditor.swift"
    )
    let tabClickTargetSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterTabClickTarget.swift"
    )
    let namingSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasNaming.swift"
    )

    XCTAssertTrue(dashboardRouteSource.contains("@State private var editingCanvasId: String?"))
    XCTAssertTrue(dashboardFooterSource.contains("isEditing: canvas.canvasId == editingCanvasId"))
    XCTAssertTrue(
      dashboardFooterComponentsSource.contains("DashboardPolicyCanvasFooterTabClickTarget(")
    )
    XCTAssertTrue(dashboardFooterComponentsSource.contains("beginRename()"))
    XCTAssertTrue(dashboardFooterComponentsSource.contains("select()"))
    XCTAssertTrue(tabClickTargetSource.contains("event.clickCount"))
    XCTAssertTrue(tabClickTargetSource.contains("coordinator?.handleClick(count: event.clickCount)"))
    XCTAssertTrue(tabClickTargetSource.contains("if count >= 2 {"))
    XCTAssertFalse(dashboardFooterSource.contains("TapGesture(count: 2)"))
    XCTAssertFalse(dashboardFooterSource.contains("Button(action: select)"))
    XCTAssertTrue(dashboardFooterComponentsSource.contains("DashboardPolicyCanvasFooterTabTitleEditor("))
    XCTAssertTrue(tabEditorSource.contains("TextField(\"Canvas title\", text: $draftTitle)"))
    XCTAssertTrue(tabEditorSource.contains(".onSubmit(submitDraft)"))
    XCTAssertTrue(tabEditorSource.contains(".onKeyPress(.escape)"))
    XCTAssertTrue(tabEditorSource.contains(".overlay(alignment: .leading)"))
    XCTAssertTrue(
      tabEditorSource.contains(".accessibilityIdentifier(accessibilityIdentifier)")
    )
    XCTAssertFalse(dashboardRouteSource.contains("DashboardPolicyCanvasNameRequest.rename"))
    XCTAssertFalse(namingSource.contains("case rename"))
  }

  func testSessionPolicyRouteRedirectsIntoDashboardPolicies() throws {
    let sessionColumnsSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let sessionRedirectSource = try previewableSourceFile(
      at: "Views/Sessions/SessionPolicyCanvasRedirectView.swift"
    )
    let sessionRootSource = try appSourceFile(
      at: "App/SessionWindowRootView.swift"
    )

    XCTAssertTrue(sessionColumnsSource.contains("SessionPolicyCanvasRedirectView()"))
    XCTAssertFalse(sessionColumnsSource.contains("PolicyCanvasView("))
    XCTAssertTrue(sessionRedirectSource.contains("openDashboardRoute(.policyCanvas)"))
    XCTAssertTrue(sessionRootSource.contains("\\.openDashboardRoute"))
    XCTAssertTrue(
      sessionRootSource.contains("windowNavigationHistory.requestDashboardRoute(route)"))
  }

  func testPolicyCanvasInspectorToggleUsesSingleCommandFocus() throws {
    let focusSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasLayoutFocus.swift"
    )
    let dispatcherSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasViewport+Dispatchers.swift"
    )
    let viewportControlSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ViewportControl.swift"
    )
    let commandsSource = try appSourceFile(
      at: "App/HarnessMonitorAppCommands.swift"
    )
    let dashboardToolbarSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardWindowToolbar.swift"
    )
    let accessibilitySource = try previewableSourceFile(
      at: "Support/HarnessMonitorAccessibilityIDs+PolicyCanvas.swift"
    )

    XCTAssertTrue(focusSource.contains("public let inspector: PolicyCanvasInspectorFocus"))
    XCTAssertTrue(focusSource.contains("PolicyCanvasInspectorFocusDispatcher"))
    XCTAssertTrue(dispatcherSource.contains("policyCanvasInspectorFocusDispatcher("))
    XCTAssertTrue(viewportControlSource.contains("inspectorFocusDispatcher:"))
    XCTAssertTrue(commandsSource.contains("policyCanvasInspectorCommands"))
    XCTAssertTrue(commandsSource.contains("policyCanvasInspectorMenuTitle"))
    XCTAssertTrue(commandsSource.contains("Show Policy Inspector"))
    XCTAssertTrue(commandsSource.contains("Hide Policy Inspector"))
    XCTAssertFalse(focusSource.contains("harnessPolicyCanvasInspectorFocus"))
    XCTAssertTrue(dashboardToolbarSource.contains("PolicyCanvasInspectorToolbarButton()"))
    XCTAssertTrue(dashboardToolbarSource.contains("import HarnessMonitorPolicyCanvas"))
    XCTAssertTrue(dashboardToolbarSource.contains("@FocusedValue(\\.harnessPolicyCanvasCommandFocus)"))
    XCTAssertTrue(dashboardToolbarSource.contains("policyCanvasInspectorButtonTitle"))
    XCTAssertTrue(dashboardToolbarSource.contains("Image(systemName: \"sidebar.trailing\")"))
    XCTAssertFalse(
      dashboardToolbarSource.contains(
        """
        ToolbarItem(placement: .primaryAction) {
                PolicyCanvasInspectorToolbarButton()
        """
      )
    )
    XCTAssertTrue(
      dashboardToolbarSource.contains(
        """
        ToolbarItem(placement: .automatic) {
                PolicyCanvasInspectorToolbarButton()
        """
      )
    )
    XCTAssertFalse(dashboardToolbarSource.contains("Text(policyCanvasInspectorButtonTitle)"))
    XCTAssertTrue(dashboardToolbarSource.contains("HarnessMonitorAccessibility.policyCanvasInspectorToolbarButton"))
    XCTAssertTrue(accessibilitySource.contains("policyCanvasInspectorToolbarButton"))
  }

  private func previewableSourceFile(at relativePath: String) throws -> String {
    try sourceFile(
      root: "Sources/HarnessMonitorUIPreviewable",
      relativePath: relativePath
    )
  }

  private func appSourceFile(at relativePath: String) throws -> String {
    try sourceFile(
      root: "Sources/HarnessMonitor",
      relativePath: relativePath
    )
  }

  private func sourceFile(root: String, relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor")
      .appendingPathComponent(root)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
