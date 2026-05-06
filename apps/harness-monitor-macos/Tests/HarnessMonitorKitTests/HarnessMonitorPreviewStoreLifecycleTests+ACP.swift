import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorPreviewStoreLifecycleTests {
  private struct PreviewAcpIdentitySetup {
    let store: HarnessMonitorStore
    let agent: AgentRegistration
    let sessionID: String
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
    #expect(
      store.selectedAcpAgents.allSatisfy { $0.agentId.hasPrefix("preview-session-agent-copilot-") })
    #expect(
      store.selectedAcpInspectAgents.allSatisfy {
        $0.agentId.hasPrefix("preview-session-agent-copilot-")
      })
    #expect(store.selectedAcpInspectObservedAt != nil)
    #expect(
      store.acpDecisionAttention(for: store.selectedAcpAgents.first?.agentId ?? "")?.count == 2)
    #expect(store.presentingAcpPermissionBatch == nil)
  }

  @Test("Preview ACP identity crosswalk keeps descriptor session managed and runtime ids distinct")
  func previewAcpIdentityCrosswalkKeepsIdentityDomainsDistinct() async throws {
    let setup = try await makePreviewAcpIdentitySetup()
    let linkage = try #require(
      setup.store.acpIdentityCrosswalk().agentLinkage(
        forSessionAgentIdentity: setup.agent.sessionAgentIdentity
      )
    )

    assertDistinctPreviewIdentities(
      store: setup.store,
      agent: setup.agent,
      linkage: linkage
    )
    assertPreviewTimelineMetadata(
      store: setup.store,
      agent: setup.agent,
      linkage: linkage,
      sessionID: setup.sessionID
    )
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

  private func makePreviewAcpIdentitySetup() async throws -> PreviewAcpIdentitySetup {
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
    return PreviewAcpIdentitySetup(store: store, agent: agent, sessionID: sessionID)
  }

  private func assertDistinctPreviewIdentities(
    store: HarnessMonitorStore,
    agent: AgentRegistration,
    linkage: AcpAgentIdentityLinkage
  ) {
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
  }

  private func assertPreviewTimelineMetadata(
    store: HarnessMonitorStore,
    agent: AgentRegistration,
    linkage: AcpAgentIdentityLinkage,
    sessionID: String
  ) {
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
}
