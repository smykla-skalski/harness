import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Sleep prevention toolbar identifier stays mirrored and wired in the session window toolbar")
  func sleepPreventionToolbarIdentifierAndWiringMirror() throws {
    #expect(
      HarnessMonitorAccessibility.sleepPreventionButton
        == "harness.toolbar.sleep-prevention"
    )

    let sleepToolbarButton = try sourceFile(named: "SleepPreventionToolbarButton.swift")
    let sessionToolbar = try sourceFile(named: "SessionWindowToolbar.swift")

    #expect(sleepToolbarButton.contains("HarnessMonitorAccessibility.sleepPreventionButton"))
    #expect(sleepToolbarButton.contains("cup.and.heat.waves.fill"))
    #expect(sleepToolbarButton.contains("cup.and.heat.waves"))
    #expect(!sleepToolbarButton.contains(".contentTransition("))
    #expect(!sleepToolbarButton.contains(".animation(.default"))
    #expect(sleepToolbarButton.contains(".harnessMCPButton("))
    #expect(sleepToolbarButton.contains("SleepPreventionToolbarSymbolLayout.size"))
    #expect(sessionToolbar.contains("SleepPreventionToolbarButton("))
  }
}
