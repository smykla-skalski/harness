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

  func testDashboardPolicyRouteUsesIntegratedFooterCanvasTabChrome() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let dashboardFooterChromeSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterTabChrome.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains(".scrollIndicators(.hidden)"))
    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterTabButtonStyle("))
    XCTAssertTrue(dashboardFooterSource.contains(".frame(maxHeight: .infinity)"))
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

  func testDashboardPolicyRouteUsesNeutralConsistentTabLabels() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains(".font(.callout.weight(.medium))"))
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

    XCTAssertTrue(dashboardFooterSource.contains("private var createCanvasTab: some View"))
    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterCreateTab("))
    XCTAssertTrue(dashboardFooterSource.contains("showsTrailingSeparator: false"))
    XCTAssertTrue(dashboardFooterSource.contains("Image(systemName: \"plus\")"))
    XCTAssertFalse(dashboardFooterSource.contains("private var createCanvasButton: some View"))
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

    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterToolsMenuButton("))
    XCTAssertTrue(dashboardFooterSource.contains("PolicyCanvasToolsMenuContent("))
    XCTAssertTrue(dashboardFooterSource.contains("Image(systemName: \"gearshape\")"))
    XCTAssertTrue(
      dashboardFooterSource.contains("HarnessMonitorAccessibility.policyCanvasToolsButton")
    )
    XCTAssertTrue(dashboardFooterSource.contains(".menuIndicator(.hidden)"))
    XCTAssertTrue(
      dashboardPolicySource.contains("PolicyCanvasAutomationPolicySheet(")
    )
    XCTAssertTrue(dashboardPolicySource.contains("viewModel: policyCanvasViewModel"))
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

    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterSaveStatus("))
    XCTAssertTrue(dashboardFooterSource.contains("activity: policyCanvasViewModel.saveActivity"))
    XCTAssertTrue(
      dashboardFooterSource.contains("HarnessMonitorAccessibility.dashboardPolicyCanvasFooterSaveStatus")
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
    let chromeSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )

    XCTAssertTrue(layoutSource.contains("ZStack(alignment: .top) {"))
    XCTAssertTrue(layoutSource.contains("PolicyCanvasChromeBannerOverlay("))
    XCTAssertTrue(layoutSource.contains("PolicyCanvasValidationPanel("))
    XCTAssertTrue(layoutSource.contains("policyCanvasViewportPane"))
    XCTAssertFalse(chromeSource.contains("if viewModel.hasPendingDocumentUpdate"))
    XCTAssertFalse(chromeSource.contains("PolicyCanvasAutosaveDisabledBanner("))
    XCTAssertFalse(chromeSource.contains("PolicyCanvasRecoveryBanner("))
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
