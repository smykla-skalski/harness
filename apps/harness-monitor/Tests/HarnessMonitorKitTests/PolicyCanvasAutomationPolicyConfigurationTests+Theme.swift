import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasAutomationPolicyConfigurationTests {
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

    #expect(
      visualStyleSource.contains(
        "static let panelBackground = Color(nsColor: .windowBackgroundColor)"
      ))
    #expect(
      !visualStyleSource.contains(
        "static let panelBackground = Color(nsColor: .underPageBackgroundColor)"
      ))
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

  @Test("Policy canvas light palette keeps the canvas distinct from host chrome")
  func policyCanvasLightPaletteKeepsTheCanvasDistinctFromHostChrome() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift")
    let gridSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGridLayers.swift")

    #expect(
      visualStyleSource.contains(
        "static let canvasBackground = Color(nsColor: .textBackgroundColor)"
      )
    )
    #expect(
      gridSource.contains(
        "NSColor.textBackgroundColor.setFill()"
      )
    )
    #expect(!gridSource.contains("fillEllipse"))
    #expect(
      !visualStyleSource.contains(
        "static let canvasBackground = Color(nsColor: .windowBackgroundColor)"
      )
    )
    #expect(!gridSource.contains("NSColor.windowBackgroundColor.setFill()"))
  }

  @Test("Policy canvas host chrome defers to the dashboard surface")
  func policyCanvasHostChromeDefersToTheDashboardSurface() throws {
    let visualStyleSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasVisualStyle.swift")
    let toolRailSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasToolRailViews.swift")
    let topBarSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift")
    let validationSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasValidationPanelView.swift")
    let editSheetSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEditSheet.swift")

    #expect(visualStyleSource.contains("static let dashboardHostBackground = Color.clear"))
    let dashboardHostBackground = ".background(PolicyCanvasVisualStyle.dashboardHostBackground)"

    #expect(toolRailSource.contains(dashboardHostBackground))
    #expect(validationSource.contains(dashboardHostBackground))
    #expect(!toolRailSource.contains(".background(PolicyCanvasVisualStyle.railBackground)"))
    #expect(!topBarSource.contains(dashboardHostBackground))
    #expect(!validationSource.contains(".background(PolicyCanvasVisualStyle.panelBackground)"))
    #expect(editSheetSource.contains(".background(PolicyCanvasVisualStyle.panelBackground)"))
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

  @Test("Policy canvas busy chrome avoids AppKit progress layout churn")
  func policyCanvasBusyChromeAvoidsAppKitProgressLayoutChurn() throws {
    let actionButtonSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeActionButton.swift")
    let saveStatusSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasSaveStatusPill.swift")

    #expect(actionButtonSource.contains("HarnessMonitorSpinner(size: 14"))
    #expect(saveStatusSource.contains("HarnessMonitorSpinner(size: 14"))
    #expect(!actionButtonSource.contains("ProgressView()"))
    #expect(!saveStatusSource.contains("ProgressView()"))
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

  @Test("Policy canvas viewport chrome follows the canvas-only theme")
  func policyCanvasViewportChromeFollowsCanvasOnlyTheme() throws {
    let workspaceSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )

    #expect(
      workspaceSource.contains(
        "PolicyCanvasEdgeKindLegend()\n"
          + "          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)"
      )
    )
    #expect(
      workspaceSource.contains(
        "PolicyCanvasZoomControls(viewModel: viewModel)\n"
          + "          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)"
      )
    )
    #expect(
      workspaceSource.contains(
        """
        VStack(alignment: .trailing, spacing: 12) {
        """
      )
    )
    #expect(workspaceSource.contains(".policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)"))
  }

  @Test("Policy canvas action bar follows the app theme")
  func policyCanvasActionBarFollowsAppTheme() throws {
    let layoutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift"
    )
    let topBarSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )

    #expect(
      layoutSource.contains(
        """
        PolicyCanvasTopBar(
        """
      )
    )
    #expect(!layoutSource.contains(".policyCanvasThemeScope()"))
    #expect(topBarSource.contains(".background(PolicyCanvasVisualStyle.chromeBackground)"))
    #expect(!topBarSource.contains(".background(PolicyCanvasVisualStyle.dashboardHostBackground)"))
  }

  @Test("Policy canvas native workspace paints the full scrollable background")
  func policyCanvasNativeWorkspacePaintsFullScrollableBackground() throws {
    let scrollCoordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(
      scrollCoordinatorSource.contains(
        "PolicyCanvasBackgroundSurface()\n"
          + "        .frame(\n"
          + "          width: workspaceLayout.workspaceSize.width,\n"
          + "          height: workspaceLayout.workspaceSize.height,"
      )
    )
    #expect(
      scrollCoordinatorSource.contains(
        ".policyCanvasResolvedThemeScope(snapshot.resolvedCanvasColorScheme)"
      )
    )
    #expect(
      !scrollCoordinatorSource.contains(
        """
        PolicyCanvasBackgroundSurface()
                  .contentShape(Rectangle())
        """
      )
    )
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
    let chromeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )

    #expect(viewModelSource.contains("var cachedAutomationPolicyCompilation"))
    #expect(viewModelSource.contains("func refreshAutomationPolicyCompilation()"))
    #expect(viewModelSource.contains("func queueAutomationPolicyCompilation()"))
    #expect(cacheSource.contains("queueAutomationPolicyCompilation()"))
    #expect(compilerSource.contains("cachedAutomationPolicyCompilation"))
    #expect(!chromeSource.contains("activeDocument: viewModel.exportDocument()"))
    // The body-read property must hand back the cached value, never recompile
    // inline. The `compile(document:)` entry point legitimately delegates to
    // `compile(nodes:edges:)`, so guard the getter body itself rather than the
    // bare call substring.
    #expect(
      compilerSource.contains(
        """
        var automationPolicyCompilation: PolicyCanvasAutomationPolicyCompilation {
            cachedAutomationPolicyCompilation
          }
        """
      )
    )
    #expect(compilerSource.contains("appendNodeText(node, to: &text)"))
    #expect(!compilerSource.contains("reachableNodes.map(nodeText).joined"))
    #expect(!compilerSource.contains("edges\n      .filter"))
    #expect(!compilerSource.contains(".map { \"\\($0.label) \\($0.condition)"))
  }
}
