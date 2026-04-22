import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("AgentDetailSection skeleton")
@MainActor
struct AgentDetailSectionTests {
  @Test("Section publishes the agents-window detail accessibility identifier")
  func publishesAccessibilityIdentifier() {
    #expect(HarnessMonitorAccessibility.agentsWindowDetailCard == "harness.agents.detail-card")
  }

  @Test("Section publishes role-action accessibility identifiers")
  func publishesRoleActionIdentifiers() {
    #expect(
      HarnessMonitorAccessibility.agentsWindowDetailRolePicker
        == "harness.agents.detail.role-picker"
    )
    #expect(
      HarnessMonitorAccessibility.agentsWindowDetailRoleChange
        == "harness.agents.detail.role-change"
    )
    #expect(
      HarnessMonitorAccessibility.agentsWindowDetailRoleRemove
        == "harness.agents.detail.role-remove"
    )
  }

  @Test("Section accepts an agent + activity and conforms to View")
  func constructsForAgent() {
    let agent = AgentRegistration(
      agentId: "agent-detail-fixture",
      name: "Fixture Agent",
      runtime: "claude",
      role: .worker,
      capabilities: ["alpha"],
      joinedAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 1,
        hookPoints: []
      ),
      persona: nil
    )
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let section = AgentDetailSection(store: store, agent: agent, activity: nil)
    _ = section.body
  }
}
