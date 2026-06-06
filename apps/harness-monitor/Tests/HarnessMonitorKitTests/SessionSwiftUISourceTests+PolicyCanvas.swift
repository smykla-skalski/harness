import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension SessionSwiftUISourceTests {
  @Test("Hidden policy minimap keeps a recenter affordance with restore menu")
  func hiddenPolicyMinimapKeepsRecenterAffordanceWithRestoreMenu() throws {
    let overlaySource = try sourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasViewportOverlayModifier.swift"
    )
    let accessibilitySource = try sourceFile(
      at: "Support/HarnessMonitorAccessibilityIDs+PolicyCanvas.swift"
    )

    #expect(overlaySource.contains("} else if !viewModel.isEmpty {"))
    #expect(overlaySource.contains("PolicyCanvasHiddenMinimapRecenterButton("))
    #expect(overlaySource.contains("viewModel.requestViewportCentering(.document)"))
    #expect(overlaySource.contains("@AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)"))
    #expect(overlaySource.contains("minimapVisible = true"))
    #expect(overlaySource.contains("Label(\"Show minimap\", systemImage: \"eye\")"))
    #expect(!overlaySource.contains(".harnessActionButtonStyle(variant: .bordered"))
    #expect(!overlaySource.contains("PolicyCanvasMinimapCenterButtonStyle()"))
    #expect(
      accessibilitySource.contains("policyCanvasHiddenMinimapRecenterButton")
    )
  }
}
