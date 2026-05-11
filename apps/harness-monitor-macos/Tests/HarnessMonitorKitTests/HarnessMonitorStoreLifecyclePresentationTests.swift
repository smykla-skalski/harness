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

  func testCachedSelectedSessionMarksActiveAcpRegistrationAsDisconnected() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-live"
    store.isShowingCachedSelectedSession = true

    let cachedAgent = makeAgent(
      agentID: "worker-cached",
      name: "Cached Worker",
      runtime: "gemini",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-cached")
    )
    store.selectedAcpAgents = [
      makeAcpSnapshot(
        acpID: "acp-worker-cached",
        sessionID: "sess-live",
        agentID: "worker-cached",
        displayName: "Cached Worker",
        pendingBatches: []
      )
    ]

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

    XCTAssertEqual(lifecycle.label, "Disconnected")
    XCTAssertEqual(lifecycle.visualStatus, .disconnected)
    XCTAssertEqual(summary.activeCount, 0)
    XCTAssertEqual(summary.disconnectedCount, 1)
  }

  func testUnavailableSelectedSessionMarksActiveAcpRegistrationAsDisconnected() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-live"
    store.connectionState = .offline("Daemon offline")

    let offlineAgent = makeAgent(
      agentID: "worker-offline",
      name: "Offline Worker",
      runtime: "gemini",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-offline")
    )
    store.selectedAcpAgents = [
      makeAcpSnapshot(
        acpID: "acp-worker-offline",
        sessionID: "sess-live",
        agentID: "worker-offline",
        displayName: "Offline Worker",
        pendingBatches: []
      )
    ]

    let lifecycle = store.agentLifecyclePresentation(
      for: offlineAgent,
      sessionID: "sess-live",
      sessionRegistrations: [offlineAgent],
      tuiStatus: nil
    )
    let summary = store.agentRuntimeSummary(
      sessionID: "sess-live",
      sessionRegistrations: [offlineAgent],
      tuiStatusByAgent: [:]
    )

    XCTAssertEqual(lifecycle.label, "Disconnected")
    XCTAssertEqual(lifecycle.visualStatus, .disconnected)
    XCTAssertEqual(summary.activeCount, 0)
    XCTAssertEqual(summary.disconnectedCount, 1)
  }

  func testNonSelectedSessionLeavesActiveAcpRegistrationUnchanged() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "other-session"
    store.isShowingCachedSelectedSession = true

    let nonSelectedAgent = makeAgent(
      agentID: "worker-other",
      name: "Other Worker",
      runtime: "gemini",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-other")
    )

    let lifecycle = store.agentLifecyclePresentation(
      for: nonSelectedAgent,
      sessionID: "sess-live",
      sessionRegistrations: [nonSelectedAgent],
      tuiStatus: nil
    )

    XCTAssertEqual(lifecycle.label, "Active")
    XCTAssertEqual(lifecycle.visualStatus, .active)
  }

  func testSelectedSessionLifecycleUsesPausedAcpWatchdogAsIdle() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-live"

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
    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-live",
      sampledAt: Date(timeIntervalSince1970: 0),
      agents: [
        AcpAgentInspectSnapshot(
          acpId: "acp-worker-live",
          sessionId: "sess-live",
          agentId: "worker-live",
          displayName: "Live Worker",
          pid: 41_001,
          pgid: 41_001,
          uptimeMs: 93_000,
          lastUpdateAt: "2026-04-28T00:00:40Z",
          lastClientCallAt: "2026-04-28T00:00:35Z",
          watchdogState: "paused",
          permissionMode: "allow_edits",
          pendingPermissions: 0,
          permissionQueueDepth: 0,
          terminalCount: 1,
          promptDeadlineRemainingMs: 0
        )
      ]
    )

    let lifecycle = store.agentLifecyclePresentation(
      for: liveAgent,
      sessionID: "sess-live",
      sessionRegistrations: [liveAgent],
      tuiStatus: nil
    )
    let summary = store.agentRuntimeSummary(
      sessionID: "sess-live",
      sessionRegistrations: [liveAgent],
      tuiStatusByAgent: [:]
    )

    XCTAssertEqual(lifecycle.label, "Idle")
    XCTAssertEqual(lifecycle.visualStatus, .idle)
    XCTAssertEqual(summary.activeCount, 0)
    XCTAssertEqual(summary.idleCount, 1)
  }

  func testSelectedSessionDetailHeadersUseLifecyclePresentationStatusLabel() throws {
    let agentDetailSource = try previewableSourceFile(
      at: "Views/Agents/AgentDetailSection.swift"
    )
    let sessionAgentDetailSource = try previewableSourceFile(
      at: "Views/Sessions/SessionAgentDetailSection.swift"
    )

    XCTAssertTrue(agentDetailSource.contains("status: lifecyclePresentation.visualStatus"))
    XCTAssertTrue(agentDetailSource.contains("statusLabel: lifecyclePresentation.label"))
    XCTAssertFalse(agentDetailSource.contains("status: agent.status"))

    XCTAssertTrue(
      sessionAgentDetailSource.contains("status: lifecyclePresentation.visualStatus")
    )
    XCTAssertTrue(
      sessionAgentDetailSource.contains("statusLabel: lifecyclePresentation.label")
    )
    XCTAssertFalse(sessionAgentDetailSource.contains("status: agent.status"))
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

  private func previewableSourceFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = appRoot
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
