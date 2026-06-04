import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  func expectSessionWindowIdentifierUsage() throws {
    let rootView = try sourceFile(named: "SessionWindowRootView.swift")
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let createRuntimeView = try sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")
    let sidebarView = try sourceFile(named: "SessionSidebar.swift")
    let sharedSidebarView = try sourceFile(named: "HarnessMonitorSidebar.swift")
    let sidebarFooterView = try sourceFile(named: "SessionSidebarFooter.swift")
    let inspectorView = try sourceFile(named: "SessionWindowInspector.swift")
    let toolbarView = try sourceFile(named: "SessionWindowToolbar.swift")
    let sharedToolbarView = try sourceFile(named: "HarnessMonitorWindowToolbar.swift")

    #expect(windowView.contains("HarnessMonitorAccessibility.sessionWindowShell"))
    #expect(
      rootView.contains(
        "HarnessMonitorAccessibility.sessionWindowToolbarSeparatorSuppressed"
      )
    )
    #expect(sidebarView.contains("HarnessMonitorAccessibility.sessionWindowSidebar"))
    #expect(sidebarView.contains("HarnessMonitorSidebar("))
    #expect(sidebarView.contains("accessibilityValue: decisionSelectionAccessibilityValue"))
    #expect(sidebarView.contains(".harnessMonitorSidebarListChrome(rowSize: sidebarRowSize)"))
    #expect(sharedSidebarView.contains("HarnessMonitorSidebarListChromeModifier"))
    #expect(sharedSidebarView.contains("SessionSidebarFooter(model: statusModel)"))
    #expect(sharedSidebarView.contains(".accessibilityIdentifier(accessibilityIdentifier)"))
    #expect(sharedSidebarView.contains(".accessibilityValue(accessibilityValue)"))
    #expect(
      sidebarFooterView.contains("HarnessMonitorAccessibility.sessionWindowStatusSurface")
    )
    #expect(sidebarFooterView.contains(".harnessMCPText("))
    #expect(
      createRuntimeView.contains("HarnessMonitorAccessibility.sessionWindowCreateProviderPane")
    )
    #expect(
      createRuntimeView.contains(
        ".accessibilityTestProbe(\n      HarnessMonitorAccessibility.sessionWindowCreateProviderPane"
      )
    )
    #expect(!createRuntimeView.contains("sessionWindowCreateModePicker"))
    #expect(toolbarView.contains(".harnessMCPButton("))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionWindowFocusModeButton"))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionNavigateBackButton"))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionNavigateForwardButton"))
    #expect(toolbarView.contains("HarnessMonitorWindowToolbar {"))
    #expect(sharedToolbarView.contains("struct HarnessMonitorWindowToolbar<"))
    #expect(
      inspectorView.contains(
        ".accessibilityTestProbe(\n      HarnessMonitorAccessibility.sessionWindowInspector"
      )
    )
    #expect(
      !inspectorView.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowInspector)"
      )
    )
    #expect(
      inspectorView.contains(
        "HarnessMonitorAccessibility.sessionWindowInspectorCloseButton"
      )
    )
  }
}
