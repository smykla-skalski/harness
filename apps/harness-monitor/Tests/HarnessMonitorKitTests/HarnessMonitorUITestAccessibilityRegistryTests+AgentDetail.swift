import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Agent detail composer-inset identifier matches sticky-bottom inset")
  func agentDetailComposerInsetIdentifierMirrors() {
    #expect(
      HarnessMonitorAccessibility.agentDetailComposerInset("worker-codex")
        == "harness.agent.detail.composer-inset.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentDetailComposerInset("Worker_Foo:Bar.1")
        == "harness.agent.detail.composer-inset.worker-foo-bar1"
    )
  }

  @Test("Agent detail section delegates scroll via column scroll view")
  func agentDetailSectionDelegatesScroll() throws {
    let section = try sourceFile(named: "AgentDetailSection.swift")
    let regions = try sourceFile(named: "AgentDetailSection+Regions.swift")

    #expect(section.contains("HarnessMonitorColumnScrollView("))
    #expect(section.contains("bottomInset: {"))
    #expect(section.contains("composerInset"))
    #expect(regions.contains("AgentDetailSendUpdateSection"))
  }

  @Test("Agent detail role actions identifier matches collapsed disclosure")
  func agentDetailRoleActionsDisclosureIdentifierMirrors() {
    #expect(
      HarnessMonitorAccessibility.agentDetailRoleActionsDisclosure("worker-codex")
        == "harness.agent.detail.role-actions.disclosure.worker-codex"
    )
  }

  @Test("Role actions render behind a disclosure in full agent pane")
  func roleActionsRenderBehindDisclosureInFullAgentPane() throws {
    let regions = try sourceFile(named: "AgentDetailSection+Regions.swift")

    #expect(regions.contains("DisclosureGroup(isExpanded: $isExpanded)"))
    #expect(regions.contains("Text(roleActionsLabel)"))
    #expect(regions.contains("agentDetailRoleActionsDisclosure"))
  }
}
