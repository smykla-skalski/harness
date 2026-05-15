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

  func testSessionWindowCachedLifecycleMarksActiveAcpRegistrationAsDisconnected() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    let cachedAgent = makeAgent(
      agentID: "worker-window-cached",
      name: "Window Cached Worker",
      runtime: "gemini",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-window-cached")
    )

    let lifecycle = store.agentLifecyclePresentation(
      for: cachedAgent,
      sessionID: "sess-window",
      sessionRegistrations: [cachedAgent],
      tuiStatus: nil,
      runtimePresentation: HarnessMonitorStore.AgentRuntimePresentationContext(
        availability: .persisted
      )
    )

    XCTAssertEqual(lifecycle.label, "Disconnected")
    XCTAssertEqual(lifecycle.visualStatus, .disconnected)
  }

  func testSessionWindowLiveLifecycleUsesExplicitAcpRuntimeContext() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    let liveAgent = makeAgent(
      agentID: "worker-window-live",
      name: "Window Live Worker",
      runtime: "gemini",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-window-live")
    )
    let runtimePresentation = HarnessMonitorStore.AgentRuntimePresentationContext(
      availability: .live,
      acpSnapshots: [
        makeAcpSnapshot(
          acpID: "acp-worker-window-live",
          sessionID: "sess-window",
          agentID: "worker-window-live",
          displayName: "Window Live Worker",
          pendingBatches: []
        )
      ]
    )

    let lifecycle = store.agentLifecyclePresentation(
      for: liveAgent,
      sessionID: "sess-window",
      sessionRegistrations: [liveAgent],
      tuiStatus: nil,
      runtimePresentation: runtimePresentation
    )
    let activity = store.agentActivityPresentation(
      for: liveAgent,
      sessionID: "sess-window",
      sessionRegistrations: [liveAgent],
      queuedTasks: [],
      tuiStatus: nil,
      runtimePresentation: runtimePresentation
    )
    let summary = store.agentRuntimeSummary(
      sessionID: "sess-window",
      sessionRegistrations: [liveAgent],
      tuiStatusByAgent: [:],
      runtimePresentation: runtimePresentation
    )

    XCTAssertEqual(lifecycle.label, "Active")
    XCTAssertEqual(lifecycle.visualStatus, .active)
    XCTAssertEqual(activity.label, "Ready")
    XCTAssertEqual(summary.activeCount, 1)
    XCTAssertEqual(summary.disconnectedCount, 0)
  }

  func testSessionWindowLiveLifecycleMarksMissingAcpRuntimeAsNotRunning() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    let staleAgent = makeAgent(
      agentID: "worker-window-stale",
      name: "Window Stale Worker",
      runtime: "gemini",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-worker-window-stale")
    )
    let runtimePresentation = HarnessMonitorStore.AgentRuntimePresentationContext(
      availability: .live
    )

    let lifecycle = store.agentLifecyclePresentation(
      for: staleAgent,
      sessionID: "sess-window",
      sessionRegistrations: [staleAgent],
      tuiStatus: nil,
      runtimePresentation: runtimePresentation
    )
    let activity = store.agentActivityPresentation(
      for: staleAgent,
      sessionID: "sess-window",
      sessionRegistrations: [staleAgent],
      queuedTasks: [],
      tuiStatus: nil,
      runtimePresentation: runtimePresentation
    )
    let summary = store.agentRuntimeSummary(
      sessionID: "sess-window",
      sessionRegistrations: [staleAgent],
      tuiStatusByAgent: [:],
      runtimePresentation: runtimePresentation
    )

    XCTAssertEqual(lifecycle.label, "Not Running")
    XCTAssertEqual(lifecycle.visualStatus, .disconnected)
    XCTAssertEqual(activity.label, "No live ACP runtime")
    XCTAssertEqual(summary.activeCount, 0)
    XCTAssertEqual(summary.notRunningCount, 1)
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
}
