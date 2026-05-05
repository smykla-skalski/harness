import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite
struct AgentDetailFactZeroHideTests {
  @Test
  func zeroValueWithFlagHides() {
    let fact = AgentDetailFact(title: "Issues", value: "0", hidesWhenZero: true)
    #expect(fact.isHiddenZero)
  }

  @Test
  func zeroValueWithoutFlagShows() {
    let fact = AgentDetailFact(title: "Issues", value: "0")
    #expect(!fact.isHiddenZero)
  }

  @Test
  func nonZeroValueWithFlagShows() {
    let fact = AgentDetailFact(title: "Issues", value: "3", hidesWhenZero: true)
    #expect(!fact.isHiddenZero)
  }

  @Test
  func paddedZeroStillHides() {
    let fact = AgentDetailFact(title: "Issues", value: "  0  ", hidesWhenZero: true)
    #expect(fact.isHiddenZero)
  }

  @Test
  func emptyValueDoesNotHide() {
    let fact = AgentDetailFact(title: "Issues", value: "", hidesWhenZero: true)
    #expect(!fact.isHiddenZero)
  }
}

@Suite
struct AgentDetailHookPointsGridTests {
  @Test
  func beforeToolHumanizes() {
    let hook = HookIntegrationDescriptor(
      name: "BeforeTool",
      typicalLatencySeconds: 0,
      supportsContextInjection: false
    )
    #expect(AgentDetailHookPointsGrid.humanizedTrigger(for: hook) == "Before each tool call")
  }

  @Test
  func afterToolHumanizes() {
    let hook = HookIntegrationDescriptor(
      name: "AfterTool",
      typicalLatencySeconds: 1,
      supportsContextInjection: true
    )
    #expect(AgentDetailHookPointsGrid.humanizedTrigger(for: hook) == "After each tool call")
  }

  @Test
  func beforePromptHumanizes() {
    let hook = HookIntegrationDescriptor(
      name: "BeforePrompt",
      typicalLatencySeconds: 0,
      supportsContextInjection: false
    )
    #expect(AgentDetailHookPointsGrid.humanizedTrigger(for: hook) == "Before each prompt")
  }

  @Test
  func afterPromptHumanizes() {
    let hook = HookIntegrationDescriptor(
      name: "AfterPrompt",
      typicalLatencySeconds: 0,
      supportsContextInjection: true
    )
    #expect(AgentDetailHookPointsGrid.humanizedTrigger(for: hook) == "After each prompt")
  }

  @Test
  func unknownHookFallsBackToName() {
    let hook = HookIntegrationDescriptor(
      name: "DuringTool",
      typicalLatencySeconds: 2,
      supportsContextInjection: false
    )
    #expect(AgentDetailHookPointsGrid.humanizedTrigger(for: hook) == "DuringTool")
  }
}
