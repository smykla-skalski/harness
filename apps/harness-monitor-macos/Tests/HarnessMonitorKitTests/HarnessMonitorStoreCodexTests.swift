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

  @Test("Start Codex run keeps the control-plane actor when no session actor is resolved")
  func startCodexRunKeepsControlPlaneActorWithoutResolvedSessionActor() async {
    let client = actorlessActionClient()
    let store = await actorlessActionStore(client: client)

    let startedRun = await store.startCodexRunSnapshot(
      prompt: "Investigate the failing suite.",
      mode: .workspaceWrite
    )

    #expect(startedRun?.runId == store.selectedCodexRun?.runId)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.emptyCockpitSummary.sessionId,
            prompt: "Investigate the failing suite.",
            mode: .workspaceWrite,
            actor: "harness-app",
            resumeThreadID: nil
          )
        ]
    )
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

  private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return store
  }
}
