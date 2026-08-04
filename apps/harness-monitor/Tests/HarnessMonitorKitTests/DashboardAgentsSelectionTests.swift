import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard agents selection")
struct DashboardAgentsSelectionTests {
  @Test("Agent selection round-trips and stays compatible with the pre-bucket identity encoding")
  func agentRoundTrip() throws {
    let identity = DashboardAgentIdentity(
      workspace: DashboardAgentWorkspaceIdentity(projectID: "harness", checkoutID: "main"),
      runtimeKind: .codex,
      managedAgentID: "codex-7"
    )
    let selection = DashboardAgentsSelection.agent(identity)

    #expect(selection.rawValue == identity.selectionRawValue)
    #expect(DashboardAgentsSelection(rawValue: selection.rawValue) == selection)
    #expect(DashboardAgentsSelection(rawValue: identity.selectionRawValue) == .agent(identity))
    #expect(selection.agentIdentity == identity)
    #expect(selection.workspaceIdentity == nil)
  }

  @Test("Workspace bucket selection round-trips and never collides with an agent")
  func workspaceRoundTrip() throws {
    let workspace = DashboardAgentWorkspaceIdentity(projectID: "ops", checkoutID: "deploy")
    let selection = DashboardAgentsSelection.workspaceDecisions(workspace)

    let restored = try #require(DashboardAgentsSelection(rawValue: selection.rawValue))
    #expect(restored == selection)
    #expect(restored.workspaceIdentity == workspace)
    #expect(restored.agentIdentity == nil)
    #expect(DashboardAgentIdentity(selectionRawValue: selection.rawValue) == nil)
  }

  @Test("Empty and malformed raw values decode to nil")
  func invalidRawValues() {
    #expect(DashboardAgentsSelection(rawValue: "") == nil)
    #expect(DashboardAgentsSelection(rawValue: "wsd:not-base64!") == nil)
  }

  @Test("Global decision selection round-trips without colliding with agent identity")
  func globalDecisionRoundTrip() {
    let selection = DashboardAgentsSelection.globalDecisions

    #expect(DashboardAgentsSelection(rawValue: selection.rawValue) == selection)
    #expect(selection.agentIdentity == nil)
    #expect(selection.workspaceIdentity == nil)
    #expect(DashboardAgentIdentity(selectionRawValue: selection.rawValue) == nil)
  }
}

@Suite("Dashboard decision action routing")
struct DashboardDecisionActionRoutingTests {
  @Test("Resolve, dismiss, and snooze actions retain their semantic route")
  func routesActionKinds() {
    let resolve = SuggestedAction(id: "nudge", title: "Nudge", kind: .nudge, payloadJSON: "{}")
    let dismiss = SuggestedAction(
      id: "dismiss",
      title: "Dismiss",
      kind: .dismiss,
      payloadJSON: "{}"
    )
    let snooze = SuggestedAction(id: "snooze", title: "Snooze", kind: .snooze, payloadJSON: "{}")

    #expect(DashboardDecisionActionRoute(action: resolve) == .resolve(actionID: "nudge"))
    #expect(DashboardDecisionActionRoute(action: dismiss) == .dismiss)
    #expect(DashboardDecisionActionRoute(action: snooze) == .snooze)
  }
}
