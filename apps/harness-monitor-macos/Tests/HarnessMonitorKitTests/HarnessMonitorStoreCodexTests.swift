import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor Codex flow")
struct HarnessMonitorStoreCodexTests {
  @Test("Start Codex run sends request and selects returned run")
  func startCodexRunSendsRequestAndSelectsReturnedRun() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    #expect(store.lastAction == "Codex run started")
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
    let store = await selectedStore(client: client)

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
    let store = await selectedStore(client: client)
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
    #expect(store.lastError?.contains("read-only mode") == true)
  }

  @Test("Start Codex run sets codexUnavailable when daemon returns 503")
  func startCodexRunSetsCodexUnavailableOn503() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    )
    let store = await selectedStore(client: client)

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == true)
    #expect(store.lastError?.contains("codex-unavailable") == true)
  }

  @Test("Successful Codex run clears codexUnavailable flag")
  func successfulCodexRunClearsCodexUnavailable() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.codexUnavailable = true

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
