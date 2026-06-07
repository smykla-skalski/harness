import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension SessionSwiftUISourceTests {
  @Test("Policy canvas zoom HUD can collapse to a percentage with restore menus")
  func policyCanvasZoomHUDCanCollapseToPercentageWithRestoreMenus() throws {
    let zoomSource = try sourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasZoomControls.swift"
    )
    let overlaySource = try sourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasViewportOverlayModifier.swift"
    )
    let chromeSource = try sourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let settingsSource = try sourceFile(
      at: "Views/Settings/SettingsPoliciesSection.swift"
    )
    let accessibilitySource = try sourceFile(
      at: "Support/HarnessMonitorAccessibilityIDs+PolicyCanvas.swift"
    )
    let settingsAccessibilitySource = try sourceFile(
      at: "Support/HarnessMonitorAccessibilityIDs.swift"
    )

    #expect(zoomSource.contains("PolicyCanvasZoomControlsDefaults.isVisibleKey"))
    #expect(zoomSource.contains("PolicyCanvasCollapsedZoomPercentage("))
    #expect(zoomSource.contains("zoomControlsVisible = false"))
    #expect(zoomSource.contains("zoomControlsVisible = true"))
    #expect(zoomSource.contains("Label(\"Hide zoom controls\", systemImage: \"eye.slash\")"))
    #expect(zoomSource.contains("Label(\"Show zoom controls\", systemImage: \"eye\")"))
    #expect(zoomSource.contains(".accessibilityHint(\"Shows the zoom controls\")"))
    #expect(zoomSource.contains("policyCanvasCollapsedZoomValue"))

    #expect(overlaySource.contains("PolicyCanvasZoomControls(viewModel: viewModel)"))
    #expect(chromeSource.contains("@AppStorage(PolicyCanvasZoomControlsDefaults.isVisibleKey)"))
    #expect(chromeSource.contains("zoomControlsVisible.toggle()"))
    #expect(
      chromeSource.contains(
        "zoomControlsVisible ? \"Hide zoom controls\" : \"Show zoom controls\""
      )
    )
    #expect(settingsSource.contains("@AppStorage(PolicyCanvasZoomControlsDefaults.isVisibleKey)"))
    #expect(settingsSource.contains("Toggle(\"Show zoom controls\", isOn: $zoomControlsVisible)"))
    #expect(
      settingsSource.contains(
        "HarnessMonitorAccessibility.settingsPoliciesZoomControlsToggle"
      )
    )
    #expect(accessibilitySource.contains("policyCanvasCollapsedZoomValue"))
    #expect(settingsAccessibilitySource.contains("settingsPoliciesZoomControlsToggle"))
  }

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
    #expect(overlaySource.contains("@FocusState private var recenterButtonFocused"))
    #expect(overlaySource.contains("@State private var recenterButtonHovered = false"))
    #expect(overlaySource.contains(".focusable()"))
    #expect(overlaySource.contains(".focused($recenterButtonFocused)"))
    #expect(overlaySource.contains(".onHover { hovering in"))
    #expect(overlaySource.contains("recenterButtonHovered = hovering"))
    #expect(overlaySource.contains("recenterButtonFocused || recenterButtonHovered"))
    #expect(
      overlaySource.contains(
        ".font(.title2.weight(recenterButtonActive ? .heavy : .regular))"
      )
    )
    #expect(overlaySource.contains(".padding(policyCanvasViewportOverlayEdgePadding)"))
    #expect(
      overlaySource.contains(
        ".padding(minimapVisible ? policyCanvasViewportOverlayEdgePadding : 0)"
      )
    )
    #expect(overlaySource.contains("PolicyCanvasHiddenMinimapRecenterButtonStyle: ButtonStyle"))
    #expect(overlaySource.contains("configuration.isPressed ? 0.92 : 1.0"))
    #expect(overlaySource.contains("configuration.isPressed ? 0.72 : 1"))
    #expect(!overlaySource.contains("Circle()"))
    #expect(!overlaySource.contains(".shadow("))
    #expect(!overlaySource.contains(".harnessActionButtonStyle(variant: .bordered"))
    #expect(!overlaySource.contains("PolicyCanvasMinimapCenterButtonStyle()"))
    #expect(
      accessibilitySource.contains("policyCanvasHiddenMinimapRecenterButton")
    )
  }
}
