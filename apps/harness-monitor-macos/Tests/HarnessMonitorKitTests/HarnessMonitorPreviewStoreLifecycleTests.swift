import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor preview store lifecycle")
struct HarnessMonitorPreviewStoreLifecycleTests {
  @Test("Preview store factory preloads cockpit state without bootstrap")
  func previewStoreFactoryPreloadsCockpitState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

    #expect(store.connectionState == .online)
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.timeline == PreviewFixtures.timeline)
    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.groupedSessions.count == 1)
    #expect(store.isBookmarked(sessionId: PreviewFixtures.summary.sessionId))
  }

  @Test("Preview store factory preloads the empty cockpit state without bootstrap")
  func previewStoreFactoryPreloadsEmptyCockpitState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .emptyCockpit)

    #expect(store.connectionState == .online)
    #expect(store.selectedSessionID == PreviewFixtures.emptyCockpitSummary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.emptyCockpitDetail)
    #expect(store.timeline.isEmpty)
    #expect(store.sessions == [PreviewFixtures.emptyCockpitSummary])
    #expect(store.groupedSessions.count == 1)
    #expect(store.selectedSession?.agents.isEmpty == true)
    #expect(store.selectedSession?.tasks.isEmpty == true)
    #expect(store.selectedSession?.signals.isEmpty == true)
  }

  @Test("Preview store factory seeds offline cached state")
  func previewStoreFactorySeedsOfflineCachedState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .offlineCached)

    #expect(
      store.connectionState == .offline(DaemonControlError.daemonOffline.localizedDescription)
    )
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.timeline == PreviewFixtures.timeline)
    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.isShowingCachedData)
    #expect(store.persistedSessionCount == 1)

    switch store.sessionDataAvailability {
    case .persisted(let reason, let sessionCount, let lastSnapshotAt):
      #expect(sessionCount == 1)
      #expect(lastSnapshotAt != nil)
      switch reason {
      case .daemonOffline(let message):
        #expect(message == DaemonControlError.daemonOffline.localizedDescription)
      case .liveDataUnavailable:
        Issue.record("Expected offline cached preview to report daemonOffline reason")
      }
    case .live, .unavailable:
      Issue.record("Expected offline cached preview to expose persisted availability")
    }
  }

  @Test("Preview store factory exposes overflow sidebar data immediately")
  func previewStoreFactorySeedsOverflowSidebarState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .sidebarOverflow)

    #expect(store.sessionFilter == .all)
    #expect(store.sessions.count == PreviewFixtures.overflowSessions.count)
    #expect(store.filteredSessionCount == PreviewFixtures.overflowSessions.count)
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.groupedSessions.isEmpty == false)
  }

  @Test("Preview store factory seeds and refreshes Agents overflow sessions")
  func previewStoreFactorySeedsAgentTuiOverflowState() async {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .agentTuiOverflow)
    let expectedTuiIDs = AgentTuiListResponse(tuis: AgentTuiPreviewSupport.overflowMixed)
      .canonicallySorted(roleByAgent: [:])
      .tuis
      .map(\.tuiId)

    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedAgentTuis.map(\.tuiId) == expectedTuiIDs)
    #expect(store.selectedAgentTui?.tuiId == expectedTuiIDs.first)

    await store.bootstrap()
    let didRefresh = await store.refreshSelectedAgentTuis()

    #expect(didRefresh)
    #expect(store.selectedAgentTuis.map(\.tuiId) == expectedTuiIDs)
    #expect(store.selectedAgentTui?.tuiId == expectedTuiIDs.first)
  }

  @Test("Preview store factory seeds dashboard state without a selected session")
  func previewStoreFactorySeedsDashboardState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

    #expect(store.connectionState == .online)
    #expect(store.sessionFilter == .active)
    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.filteredSessionCount == 1)
    #expect(store.groupedSessions.count == 1)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isBookmarked(sessionId: PreviewFixtures.summary.sessionId))
  }

  @Test("Preview store factory seeds dashboard landing with default filter state")
  func previewStoreFactorySeedsDashboardLandingState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLanding)

    #expect(store.connectionState == .online)
    #expect(store.sessionFilter == .all)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
  }

  @Test("Preview bootstrap auto-selects the declared ready session")
  func previewBootstrapAutoSelectsDeclaredReadySession() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: PreviewHarnessClient())
    )

    await store.bootstrapIfNeeded()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.timeline == PreviewFixtures.timeline)
  }

  @Test("Preview daemon bootstrap skips live connection telemetry")
  func previewDaemonBootstrapSkipsLiveConnectionTelemetry() async {
    let store = HarnessMonitorStore(
      daemonController: PreviewDaemonController(mode: .populated)
    )

    await store.bootstrapIfNeeded()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.connectionState == .online)
    #expect(store.connectionEvents.isEmpty)
    #expect(store.connectionMetrics.connectedSince == nil)
    #expect(store.connectionMetrics.messagesReceived == 0)
    #expect(store.connectionMetrics.messagesSent == 0)
    #expect(store.manifestWatcher == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.globalStreamTask == nil)
    #expect(store.sessionStreamTask == nil)
  }

  @Test("Dashboard landing preview bootstraps without auto-selecting a session")
  func dashboardLandingPreviewBootstrapsWithoutAutoSelectingSession() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(
        client: PreviewHarnessClient(
          fixtures: .dashboardLanding,
          isLaunchAgentInstalled: true
        )
      )
    )

    await store.bootstrapIfNeeded()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
  }

  @Test("Task drop preview queues work on a busy worker")
  func taskDropPreviewQueuesWorkOnBusyWorker() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskDrop,
      isLaunchAgentInstalled: true
    )

    let detail = try await client.dropTask(
      sessionID: PreviewFixtures.taskDropSummary.sessionId,
      taskID: PreviewFixtures.taskDropTask.taskId,
      request: TaskDropRequest(
        actor: "leader-claude",
        target: .agent(agentId: "worker-codex"),
        queuePolicy: .locked
      )
    )

    let task = try #require(
      detail.tasks.first { $0.taskId == PreviewFixtures.taskDropTask.taskId }
    )
    #expect(task.assignedTo == "worker-codex")
    #expect(task.isQueuedForWorker)
    #expect(task.queuePolicy == .locked)
    #expect(task.queuedAt != nil)
    #expect(task.status == .open)

    let agent = try #require(detail.agents.first { $0.agentId == "worker-codex" })
    #expect(agent.currentTaskId == "task-ui")
    #expect(detail.session.metrics.openTaskCount == 1)
  }

  @Test("Preview client seeds ACP managed agents when preview permissions start enabled")
  func previewClientSeedsAcpManagedAgents() async throws {
    let previousValue = Foundation.ProcessInfo.processInfo.environment[
      "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"
    ]
    Darwin.setenv("HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START", "1", 1)
    defer {
      if let previousValue {
        Darwin.setenv("HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START", previousValue, 1)
      } else {
        Darwin.unsetenv("HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START")
      }
    }

    let client = PreviewHarnessClient(
      fixtures: .populated,
      isLaunchAgentInstalled: true
    )

    let response = try await client.managedAgents(sessionID: PreviewFixtures.summary.sessionId)
    let acpAgent = try #require(response.agents.compactMap(\.acp).first)
    let inspect = try await client.acpInspect(sessionID: PreviewFixtures.summary.sessionId)
    let inspectedAgent = try #require(inspect.agents.first)

    #expect(acpAgent.agentId.hasPrefix("preview-session-agent-copilot-"))
    #expect(acpAgent.pendingPermissions == 2)
    #expect(acpAgent.pendingPermissionBatches.map(\.batchId) == ["preview-acp-permission-1"])
    #expect(inspectedAgent.agentId.hasPrefix("preview-session-agent-copilot-"))
    #expect(inspectedAgent.promptDeadlineRemainingMs == 95_000)
  }

  @Test("Preview client start ACP refreshes session detail agents")
  func previewClientStartAcpRefreshesSessionDetailAgents() async throws {
    let client = PreviewHarnessClient(
      fixtures: .populated,
      isLaunchAgentInstalled: true
    )
    let sessionID = PreviewFixtures.summary.sessionId

    _ = try await client.startManagedAcpAgent(
      sessionID: sessionID,
      request: AcpAgentStartRequest(
        agent: "copilot",
        role: .leader,
        fallbackRole: .observer,
        capabilities: ["acp"]
      )
    )

    let detail = try await client.sessionDetail(id: sessionID, scope: nil)
    let agent = try #require(detail.agents.first { $0.runtime == "copilot" })

    #expect(agent.agentId.hasPrefix("preview-session-agent-copilot-"))
    #expect(agent.agentId != "copilot")
    #expect(agent.name == "GitHub Copilot")
    #expect(agent.runtime == "copilot")
    #expect(agent.role == .observer)
    #expect(agent.status == .active)
    #expect(agent.managedAgent?.kind == .acp)
    #expect(agent.managedAgentID?.hasPrefix("preview-managed-agent-") == true)
    #expect(agent.managedAgentID != agent.sessionAgentID)
    #expect(agent.runtimeSessionID?.hasPrefix("preview-runtime-session-") == true)
    #expect(agent.runtimeSessionID != agent.sessionAgentID)
    #expect(detail.session.leaderId == PreviewFixtures.summary.leaderId)
    #expect(detail.session.metrics.agentCount == detail.agents.count)

    await #expect(throws: HarnessMonitorAPIError.self) {
      _ = try await client.managedAgent(agentID: agent.sessionAgentID)
    }
  }

  @Test("Preview bootstrap refresh keeps ACP managed agents on selected session")
  func previewBootstrapRefreshKeepsAcpManagedAgents() async {
    let previousValue = Foundation.ProcessInfo.processInfo.environment[
      "HARNESS_MONITOR_PREVIEW_ACP_PENDING"
    ]
    Darwin.setenv("HARNESS_MONITOR_PREVIEW_ACP_PENDING", "1", 1)
    defer {
      if let previousValue {
        Darwin.setenv("HARNESS_MONITOR_PREVIEW_ACP_PENDING", previousValue, 1)
      } else {
        Darwin.unsetenv("HARNESS_MONITOR_PREVIEW_ACP_PENDING")
      }
    }

    let store = HarnessMonitorStore(
      daemonController: PreviewDaemonController(mode: .populated)
    )

    await store.bootstrapIfNeeded()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedAcpAgents.allSatisfy { $0.agentId.hasPrefix("preview-session-agent-copilot-") })
    #expect(store.selectedAcpInspectAgents.allSatisfy { $0.agentId.hasPrefix("preview-session-agent-copilot-") })
    #expect(store.selectedAcpInspectObservedAt != nil)
    #expect(store.acpDecisionAttention(for: store.selectedAcpAgents.first?.agentId ?? "")?.count == 2)
    #expect(store.presentingAcpPermissionBatch == nil)
  }

  @Test("Preview ACP identity crosswalk keeps descriptor session managed and runtime ids distinct")
  func previewAcpIdentityCrosswalkKeepsIdentityDomainsDistinct() async throws {
    let client = PreviewHarnessClient(
      fixtures: .populated,
      isLaunchAgentInstalled: true
    )
    let sessionID = PreviewFixtures.summary.sessionId
    _ = try await client.startManagedAcpAgent(
      sessionID: sessionID,
      request: AcpAgentStartRequest(
        agent: "copilot",
        role: .leader,
        fallbackRole: .observer,
        capabilities: ["acp"]
      )
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.acpAgentDescriptorsByID["copilot"] = AcpAgentDescriptor(
      id: "copilot",
      displayName: "GitHub Copilot",
      capabilities: ["acp"],
      launchCommand: "copilot",
      launchArgs: [],
      envPassthrough: [],
      modelCatalog: nil,
      installHint: nil,
      doctorProbe: AcpDoctorProbe(command: "copilot", args: ["doctor"])
    )

    await store.bootstrap()
    await store.selectSession(sessionID)

    let detail = try await client.sessionDetail(id: sessionID, scope: nil)
    let agent = try #require(detail.agents.first { $0.runtime == "copilot" })
    let linkage = try #require(
      store.acpIdentityCrosswalk().agentLinkage(
        forSessionAgentIdentity: agent.sessionAgentIdentity
      )
    )

    #expect(linkage.descriptorIdentity == Optional(AcpDescriptorID(rawValue: "copilot")))
    #expect(linkage.sessionAgentIdentity == agent.sessionAgentIdentity)
    #expect(linkage.sessionAgentIdentity?.rawValue != linkage.descriptorIdentity?.rawValue)
    #expect(
      store.acpIdentityCrosswalk().agentLinkage(
        forSessionAgentIdentity: SessionAgentID(rawValue: "copilot")
      ) == nil
    )
    #expect(
      store.acpIdentityCrosswalk().agentLinkage(
        forSessionAgentIdentity: SessionAgentID(rawValue: linkage.managedAgentIdentity.rawValue)
      ) == nil
    )
    #expect(
      store.acpIdentityCrosswalk().agentLinkage(
        forRuntimeSessionIdentity: RuntimeSessionID(rawValue: agent.agentId)
      ) == nil
    )
    #expect(linkage.managedAgentIdentity.rawValue.hasPrefix("preview-managed-agent-"))
    #expect(linkage.managedAgentIdentity.rawValue != linkage.sessionAgentIdentity?.rawValue)
    #expect(linkage.runtimeSessionIdentity?.rawValue.hasPrefix("preview-runtime-session-") == true)
    #expect(linkage.runtimeSessionIdentity?.rawValue != linkage.sessionAgentIdentity?.rawValue)
    #expect(
      store.acpAgentSnapshot(
        for: SessionAgentID(rawValue: linkage.managedAgentIdentity.rawValue)
      ) == nil
    )
    #expect(
      store.managedAgentNudgeTarget(
        forSessionAgentIdentity: SessionAgentID(rawValue: linkage.managedAgentIdentity.rawValue)
      ) == nil
    )

    let metadata = store.acpToolCallTimelineMetadata(
      for: AcpEventBatchPayload(
        acpId: linkage.managedAgentIdentity.rawValue,
        sessionId: sessionID,
        rawCount: 1,
        events: [
          AcpConversationEvent(
            timestamp: "2026-05-06T00:00:00Z",
            sequence: 1,
            kind: .object([
              "type": .string("tool_invocation"),
              "tool_name": .string("Read"),
              "invocation_id": .string("call-1"),
            ]),
            agent: agent.agentId,
            sessionId: sessionID
          )
        ]
      )
    )
    #expect(metadata.managedAgentID == linkage.managedAgentIdentity.rawValue)
    #expect(metadata.sessionAgentID == agent.agentId)
    #expect(metadata.displayName == "GitHub Copilot")
    #expect(metadata.capabilityTags == ["acp"])
  }

  @Test("Preview store factory seeds ACP bridge outage state when preview bridge is down")
  func previewStoreFactorySeedsAcpBridgeOutageState() {
    let previousValue = Foundation.ProcessInfo.processInfo.environment[
      "HARNESS_MONITOR_PREVIEW_ACP_PENDING"
    ]
    Darwin.setenv("HARNESS_MONITOR_PREVIEW_ACP_PENDING", "1", 1)
    defer {
      if let previousValue {
        Darwin.setenv("HARNESS_MONITOR_PREVIEW_ACP_PENDING", previousValue, 1)
      } else {
        Darwin.unsetenv("HARNESS_MONITOR_PREVIEW_ACP_PENDING")
      }
    }

    let store = HarnessMonitorPreviewStoreFactory.makeStore(
      for: .cockpitLoaded,
      hostBridgeOverride: PreviewHostBridgeOverride(
        bridgeStatus: BridgeStatusReport(running: false),
        reconfigureBehavior: .unsupported
      )
    )

    #expect(store.daemonStatus?.manifest?.sandboxed == true)
    #expect(store.daemonStatus?.manifest?.hostBridge.running == false)
    #expect(store.acpUnavailable == true)
    #expect(store.acpBridgeHTTPIncident != nil)
    #expect(store.contentUI.chrome.acpBridgeBanner?.retryCount == 0)
  }

  @Test("Preview store factory seeds empty state without stale selection")
  func previewStoreFactorySeedsEmptyState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)

    #expect(
      store.connectionState == .offline(DaemonControlError.daemonOffline.localizedDescription)
    )
    #expect(store.sessionFilter == .active)
    #expect(store.sessions.isEmpty)
    #expect(store.filteredSessionCount == 0)
    #expect(store.groupedSessions.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isShowingCachedData == false)
  }

  @Test("Empty preview daemon auto-registers and connects during bootstrap")
  func emptyPreviewDaemonTransitionsOnlineAfterStart() async {
    let store = HarnessMonitorStore(daemonController: PreviewDaemonController(mode: .empty))

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.daemonStatus?.launchAgent.installed == true)
    #expect(store.sessions.isEmpty)
    #expect(store.health?.status == "ok")
  }
}
