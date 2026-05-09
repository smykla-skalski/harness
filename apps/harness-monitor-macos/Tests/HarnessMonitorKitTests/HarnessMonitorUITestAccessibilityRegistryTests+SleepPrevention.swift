import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Sleep prevention toolbar identifier stays mirrored and wired across windows")
  func sleepPreventionToolbarIdentifierAndWiringMirror() throws {
    #expect(
      HarnessMonitorAccessibility.sleepPreventionButton
        == "harness.toolbar.sleep-prevention"
    )

    let sleepToolbarButton = try sourceFile(named: "SleepPreventionToolbarButton.swift")
    let contentToolbar = try sourceFile(named: "ContentToolbarItems.swift")
    let sessionToolbar = try sourceFile(named: "SessionWindowToolbar.swift")
    let workspaceWindow = try sourceFile(named: "WorkspaceWindowView.swift")

    #expect(
      sleepToolbarButton.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)"
      )
    )
    #expect(sleepToolbarButton.contains("cup.and.heat.waves.fill"))
    #expect(sleepToolbarButton.contains("cup.and.heat.waves"))
    #expect(sleepToolbarButton.contains(".contentTransition("))
    #expect(
      sleepToolbarButton.contains(
        ".replace.magic(fallback: .downUp.wholeSymbol)"
      )
    )
    #expect(sleepToolbarButton.contains("options: .nonRepeating"))
    #expect(sleepToolbarButton.contains("SleepPreventionToolbarSymbolLayout.size"))
    #expect(contentToolbar.contains("SleepPreventionToolbarButton("))
    #expect(sessionToolbar.contains("SleepPreventionToolbarButton("))
    #expect(workspaceWindow.contains("ToolbarItem(placement: .primaryAction)"))
    #expect(workspaceWindow.contains("SleepPreventionToolbarButton("))
  }
}
