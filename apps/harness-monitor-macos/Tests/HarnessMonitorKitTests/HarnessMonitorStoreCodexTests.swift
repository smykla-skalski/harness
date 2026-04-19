import Darwin
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor codex agents")
struct HarnessMonitorStoreCodexTests {
  @Test("Start Codex run sends request and selects returned run")
  func startCodexRunSendsRequestAndSelectsReturnedRun() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let started = await store.startCodexRun(
      prompt: "Investigate the failing suite.",
      mode: .workspaceWrite,
      actor: "leader-claude"
    )

    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Investigate the failing suite.",
            mode: .workspaceWrite,
            actor: "leader-claude",
            resumeThreadID: nil
          )
        ]
    )
    #expect(store.selectedCodexRun?.prompt == "Investigate the failing suite.")
    #expect(store.selectedCodexRun?.mode == .workspaceWrite)
    #expect(store.currentSuccessFeedbackMessage == "Codex run started")
  }

  @Test("Start Codex run returns the started snapshot")
  func startCodexRunReturnsStartedSnapshot() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let startedRun = await store.startCodexRunSnapshot(
      prompt: "Investigate the failing suite.",
      mode: .workspaceWrite,
      actor: "leader-claude"
    )

    #expect(startedRun?.runId == store.selectedCodexRun?.runId)
    #expect(startedRun?.prompt == "Investigate the failing suite.")
    #expect(startedRun?.mode == .workspaceWrite)
  }

  @Test("Starting another Codex run reselects the newly started run")
  func startingAnotherCodexRunReselectsNewRun() async {
    let client = RecordingHarnessClient()
    let existingRun = client.codexRunFixture(
      runID: "codex-run-existing",
      mode: .report,
      status: .completed,
      prompt: "Existing run"
    )
    client.configureCodexRuns([existingRun], for: PreviewFixtures.summary.sessionId)
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.selectedCodexRuns = [existingRun]
    store.selectedCodexRun = existingRun
    #expect(store.selectedCodexRun?.runId == existingRun.runId)

    let started = await store.startCodexRun(
      prompt: "Start a fresh run.",
      mode: .approval,
      actor: "leader-claude"
    )

    #expect(started)
    #expect(store.selectedCodexRuns.map(\.runId) == ["codex-run-2", "codex-run-existing"])
    #expect(store.selectedCodexRun?.runId == "codex-run-2")
    #expect(store.selectedCodexRun?.prompt == "Start a fresh run.")
    #expect(store.selectedCodexRun?.mode == .approval)
  }

  @Test("Codex approval resolution clears pending approval")
  func codexApprovalResolutionClearsPendingApproval() async {
    let client = RecordingHarnessClient()
    let approval = client.codexApprovalFixture()
    let run = client.codexRunFixture(
      mode: .approval,
      status: .waitingApproval,
      pendingApprovals: [approval]
    )
    client.configureCodexRuns([run], for: PreviewFixtures.summary.sessionId)
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let resolved = await store.resolveCodexApproval(
      runID: run.runId,
      approvalID: approval.approvalId,
      decision: .accept
    )

    #expect(resolved)
    #expect(
      client.recordedCalls()
        == [
          .resolveCodexApproval(
            runID: run.runId,
            approvalID: approval.approvalId,
            decision: .accept
          )
        ]
    )
    #expect(store.selectedCodexRun?.pendingApprovals.isEmpty == true)
    #expect(store.selectedCodexRun?.status == .running)
  }

  @Test("Codex stream update refreshes selected run")
  func codexStreamUpdateRefreshesSelectedRun() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    let run = client.codexRunFixture(status: .completed, finalMessage: "Done.")

    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-09T10:02:00Z",
        sessionId: PreviewFixtures.summary.sessionId,
        kind: .codexRunUpdated(run)
      )
    )

    #expect(store.selectedCodexRun?.runId == run.runId)
    #expect(store.selectedCodexRun?.status == .completed)
    #expect(store.selectedCodexRun?.finalMessage == "Done.")
  }

  @Test("Codex actions stay read-only while daemon is offline")
  func codexActionsStayReadOnlyWhileDaemonIsOffline() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.connectionState = .offline("daemon down")

    let started = await store.startCodexRun(prompt: "Patch it.", mode: .workspaceWrite)

    #expect(started == false)
    #expect(client.recordedCalls().isEmpty)
    #expect(store.currentFailureFeedbackMessage?.contains("read-only mode") == true)
  }

  @Test("Start Codex run sets codexUnavailable when sandboxed daemon returns 503")
  func startCodexRunSetsCodexUnavailableOnSandboxed503() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    )
    let daemon = RecordingDaemonController(
      client: client,
      statusReport: sandboxedStatus(hostBridge: HostBridgeManifest())
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == true)
    #expect(store.currentFailureFeedbackMessage?.contains("codex-unavailable") == true)
  }

  @Test(
    "Sandboxed 503 refreshes bridge state and retries Codex start once when the bridge is healthy")
  func startCodexRunRetriesOnceAfterSandboxed503WhenBridgeRefreshesHealthy() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartErrors([
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    ])
    let daemon = RecordingDaemonController(
      client: client,
      statusReport: sandboxedStatus(
        hostBridge: HostBridgeManifest(
          running: true,
          socketPath: "/tmp/bridge.sock",
          capabilities: [
            "codex": HostBridgeCapabilityManifest(
              healthy: true,
              transport: "websocket",
              endpoint: "ws://127.0.0.1:4500"
            )
          ]
        )
      )
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
        ]
    )
    #expect(store.codexUnavailable == false)
    #expect(store.daemonStatus?.manifest?.hostBridge.running == true)
    #expect(store.daemonStatus?.manifest?.hostBridge.capabilities["codex"]?.healthy == true)
    #expect(store.currentSuccessFeedbackMessage == "Codex run started")
  }

  @Test("Sandboxed 503 keeps running bridge unavailable when the retry still fails")
  func startCodexRunKeepsRunningBridgeUnavailableWhenRetryStillFails() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartErrors([
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable"),
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable"),
    ])
    let daemon = RecordingDaemonController(
      client: client,
      statusReport: sandboxedStatus(
        hostBridge: HostBridgeManifest(
          running: true,
          socketPath: "/tmp/bridge.sock",
          capabilities: [
            "codex": HostBridgeCapabilityManifest(
              healthy: true,
              transport: "websocket",
              endpoint: "ws://127.0.0.1:4500"
            )
          ]
        )
      )
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
        ]
    )
    #expect(store.codexUnavailable == true)
    #expect(store.hostBridgeCapabilityState(for: "codex") == .unavailable)
    #expect(
      store.hostBridgeStartCommand(for: "codex") == "harness bridge reconfigure --enable codex")
    #expect(store.currentFailureFeedbackMessage?.contains("codex-unavailable") == true)
  }

  @Test("Start Codex run keeps host bridge ready when daemon is not sandboxed")
  func startCodexRunDoesNotSetCodexUnavailableOnUnsandboxed503() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    )
    let store = await selectedStore(client: client)

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == false)
    #expect(store.currentFailureFeedbackMessage?.contains("codex-unavailable") == true)
  }

  @Test("Successful Codex run clears codexUnavailable flag")
  func successfulCodexRunClearsCodexUnavailable() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.hostBridgeCapabilityIssues["codex"] = .unavailable

    let started = await store.startCodexRun(prompt: "Patch it.", mode: .report)

    #expect(started == true)
    #expect(store.codexUnavailable == false)
  }

  @Test("Non-503 error does not set codexUnavailable")
  func non503ErrorDoesNotSetCodexUnavailable() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 400, message: "bad request")
    )
    let store = await selectedStore(client: client)

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == false)
  }

  private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return store
  }
}
