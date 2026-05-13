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

    #expect(sleepToolbarButton.contains("HarnessMonitorAccessibility.sleepPreventionButton"))
    #expect(sleepToolbarButton.contains("cup.and.heat.waves.fill"))
    #expect(sleepToolbarButton.contains("cup.and.heat.waves"))
    #expect(sleepToolbarButton.contains(".contentTransition("))
    #expect(sleepToolbarButton.contains(".harnessMCPButton("))
    #expect(
      sleepToolbarButton.contains(
        ".replace.magic(fallback: .downUp.wholeSymbol)"
      )
    )
    #expect(sleepToolbarButton.contains("options: .nonRepeating"))
    #expect(sleepToolbarButton.contains("SleepPreventionToolbarSymbolLayout.size"))
    #expect(contentToolbar.contains("SleepPreventionToolbarButton("))
    #expect(sessionToolbar.contains("SleepPreventionToolbarButton("))
  }
}
