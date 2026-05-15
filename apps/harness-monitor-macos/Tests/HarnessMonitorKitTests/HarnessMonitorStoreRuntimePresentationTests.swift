import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTests {
  @Test("Selected-session lifecycle marks stale ACP registrations as not running")
  func selectedSessionLifecycleMarksStaleAcpRegistrationsAsNotRunning() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    store.selectedSessionID = "sess-live"

    let staleAgent = AgentRegistration(
      agentId: "worker-stale",
      name: "Stale Worker",
      runtime: "copilot",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .active,
      agentSessionId: "worker-stale-session",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-stale"),
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
    let liveAgent = AgentRegistration(
      agentId: "worker-live",
      name: "Live Worker",
      runtime: "copilot",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .active,
      agentSessionId: "worker-live-session",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-live"),
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )

    store.selectedAcpAgents = [
      makeAcpSnapshot(
        acpID: "acp-worker-live",
        sessionID: "sess-live",
        agentID: "worker-live",
        displayName: "Live Worker",
        pendingBatches: []
      )
    ]

    let staleLifecycle = store.agentLifecyclePresentation(
      for: staleAgent,
      sessionID: "sess-live",
      sessionRegistrations: [staleAgent, liveAgent],
      tuiStatus: nil
    )
    let liveLifecycle = store.agentLifecyclePresentation(
      for: liveAgent,
      sessionID: "sess-live",
      sessionRegistrations: [staleAgent, liveAgent],
      tuiStatus: nil
    )

    #expect(staleLifecycle.label == "Not Running")
    #expect(staleLifecycle.visualStatus == .disconnected)
    #expect(liveLifecycle.label == "Active")
    #expect(liveLifecycle.visualStatus == .active)
  }

  @Test("Agent activity presentation never shows ready for disconnected or cached agents")
  func agentActivityPresentationNeverShowsReadyForDisconnectedOrCachedAgents() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities

    let disconnectedAgent = AgentRegistration(
      agentId: "worker-disconnected",
      name: "Disconnected Worker",
      runtime: "codex",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .disconnected,
      agentSessionId: "worker-disconnected-session",
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )

    let activeAgent = AgentRegistration(
      agentId: "worker-active",
      name: "Active Worker",
      runtime: "codex",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .active,
      agentSessionId: "worker-active-session",
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )

    let disconnectedPresentation = store.agentActivityPresentation(
      for: disconnectedAgent,
      sessionID: "sess-live",
      sessionRegistrations: [disconnectedAgent],
      queuedTasks: [],
      tuiStatus: nil
    )
    let cachedPresentation = store.agentActivityPresentation(
      for: activeAgent,
      sessionID: "sess-live",
      sessionRegistrations: [activeAgent],
      queuedTasks: [],
      tuiStatus: nil
    )

    #expect(disconnectedPresentation.label == "Disconnected")
    #expect(cachedPresentation.label == "Snapshot")
  }

  @Test("Cached selected-session ACP agents render as disconnected")
  func cachedSelectedSessionAcpAgentsRenderAsDisconnected() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    store.selectedSessionID = "sess-live"
    store.isShowingCachedSelectedSession = true
    store.selectedAcpAgents = [
      makeAcpSnapshot(
        acpID: "acp-worker-cached",
        sessionID: "sess-live",
        agentID: "worker-cached",
        displayName: "Cached Worker",
        pendingBatches: []
      )
    ]

    let cachedAgent = AgentRegistration(
      agentId: "worker-cached",
      name: "Cached Worker",
      runtime: "gemini",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .active,
      agentSessionId: "worker-cached-session",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-cached"),
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )

    let lifecycle = store.agentLifecyclePresentation(
      for: cachedAgent,
      sessionID: "sess-live",
      sessionRegistrations: [cachedAgent],
      tuiStatus: nil
    )
    let summary = store.agentRuntimeSummary(
      sessionID: "sess-live",
      sessionRegistrations: [cachedAgent],
      tuiStatusByAgent: [:]
    )

    #expect(lifecycle.label == "Disconnected")
    #expect(lifecycle.visualStatus == .disconnected)
    #expect(summary.activeCount == 0)
    #expect(summary.disconnectedCount == 1)
  }

  @Test("Selected-session runtime summary counts stale ACP registrations separately")
  func selectedSessionRuntimeSummaryCountsStaleAcpRegistrationsSeparately() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    store.selectedSessionID = "sess-live"

    let liveAgent = AgentRegistration(
      agentId: "worker-live",
      name: "Live Worker",
      runtime: "copilot",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .active,
      agentSessionId: "worker-live-session",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-live"),
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
    let staleAgent = AgentRegistration(
      agentId: "worker-stale",
      name: "Stale Worker",
      runtime: "copilot",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .active,
      agentSessionId: "worker-stale-session",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-stale"),
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )

    store.selectedAcpAgents = [
      makeAcpSnapshot(
        acpID: "acp-worker-live",
        sessionID: "sess-live",
        agentID: "worker-live",
        displayName: "Live Worker",
        pendingBatches: []
      )
    ]

    let summary = store.agentRuntimeSummary(
      sessionID: "sess-live",
      sessionRegistrations: [liveAgent, staleAgent],
      tuiStatusByAgent: [:]
    )

    #expect(summary.registeredCount == 2)
    #expect(summary.activeCount == 1)
    #expect(summary.notRunningCount == 1)
    #expect(summary.disconnectedCount == 0)
  }
}
