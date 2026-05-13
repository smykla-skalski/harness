import Testing

extension SessionWindowFlowTests {
  @Test("Sidebar density keeps strict default and maps legacy values")
  func sidebarDensityResolvesStrictDefaultAndLegacyValues() {
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.defaultMode == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: nil) == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "strict") == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "dense") == .dense)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "concise") == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "detailed") == .dense)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "unknown") == .strict)
  }
}
