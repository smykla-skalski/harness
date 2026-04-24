import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("External Agents sidebar section")
@MainActor
struct AgentsSidebarExternalSectionTests {
  @Test("External-tab identifier is scoped under agent-tui namespace")
  func externalTabIdentifier() {
    #expect(
      HarnessMonitorAccessibility.agentTuiExternalTab("alpha-agent")
        == "harness.sheet.agent-tui.external-tab.alpha-agent"
    )
  }

  @Test("External-tab identifier slugs non-URL-safe characters")
  func externalTabIdentifierSlugsAgentID() {
    #expect(
      HarnessMonitorAccessibility.agentTuiExternalTab("Claude Helper")
        == "harness.sheet.agent-tui.external-tab.claude-helper"
    )
  }
}
