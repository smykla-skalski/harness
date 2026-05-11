import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreLifecyclePresentationTests: XCTestCase {
  func testSelectedSessionLifecycleMarksStaleAcpRegistrationsAsNotRunning() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-live"

    let staleAgent = makeAgent(
      agentID: "worker-stale",
      name: "Stale Worker",
      runtime: "copilot",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-stale")
    )
    let liveAgent = makeAgent(
      agentID: "worker-live",
      name: "Live Worker",
      runtime: "copilot",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-live")
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

    XCTAssertEqual(staleLifecycle.label, "Not Running")
    XCTAssertEqual(staleLifecycle.visualStatus, .disconnected)
    XCTAssertEqual(liveLifecycle.label, "Active")
    XCTAssertEqual(liveLifecycle.visualStatus, .active)
  }

  func testSelectedSessionRuntimeSummarySeparatesStaleAcpRegistrations() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-live"

    let liveAgent = makeAgent(
      agentID: "worker-live",
      name: "Live Worker",
      runtime: "copilot",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-live")
    )
    let staleAgent = makeAgent(
      agentID: "worker-stale",
      name: "Stale Worker",
      runtime: "copilot",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-stale")
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

    XCTAssertEqual(summary.registeredCount, 2)
    XCTAssertEqual(summary.activeCount, 1)
    XCTAssertEqual(summary.notRunningCount, 1)
    XCTAssertEqual(summary.disconnectedCount, 0)
  }

  func testDisconnectedAndCachedAgentsDoNotShowReadyActivity() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    let disconnectedAgent = makeAgent(
      agentID: "worker-disconnected",
      name: "Disconnected Worker",
      runtime: "codex",
      status: .disconnected
    )
    let cachedAgent = makeAgent(
      agentID: "worker-active",
      name: "Active Worker",
      runtime: "codex"
    )

    let disconnectedPresentation = store.agentActivityPresentation(
      for: disconnectedAgent,
      sessionID: "sess-live",
      sessionRegistrations: [disconnectedAgent],
      queuedTasks: [],
      tuiStatus: nil
    )
    let cachedPresentation = store.agentActivityPresentation(
      for: cachedAgent,
      sessionID: "sess-live",
      sessionRegistrations: [cachedAgent],
      queuedTasks: [],
      tuiStatus: nil
    )

    XCTAssertEqual(disconnectedPresentation.label, "Disconnected")
    XCTAssertEqual(cachedPresentation.label, "Snapshot")
  }

  private func makeAgent(
    agentID: String,
    name: String,
    runtime: String,
    status: AgentStatus = .active,
    managedAgent: ManagedAgentRef? = nil
  ) -> AgentRegistration {
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    return AgentRegistration(
      agentId: agentID,
      name: name,
      runtime: runtime,
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: status,
      agentSessionId: "\(agentID)-session",
      managedAgent: managedAgent,
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
  }
}
