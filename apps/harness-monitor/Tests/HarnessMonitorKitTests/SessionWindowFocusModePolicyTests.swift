import HarnessMonitorUIPreviewable
import Testing

struct SessionWindowFocusModePolicyTests {
  @Test("Focus mode uses route content only for route-level selections")
  func focusModeUsesRouteContentOnlyForRouteLevelSelections() {
    #expect(
      SessionWindowFocusModePolicy.usesRouteContent(selection: .route(.overview))
    )
    #expect(
      SessionWindowFocusModePolicy.usesRouteContent(selection: .route(.decisions))
    )
    #expect(
      !SessionWindowFocusModePolicy.usesRouteContent(
        selection: .agent(sessionID: "sess-alpha", agentID: "agent-a")
      )
    )
    #expect(
      !SessionWindowFocusModePolicy.usesRouteContent(
        selection: .decision(sessionID: "sess-alpha", decisionID: "decision-a")
      )
    )
  }
}
