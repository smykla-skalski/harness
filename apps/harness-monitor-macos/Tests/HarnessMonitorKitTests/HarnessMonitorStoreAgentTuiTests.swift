import Darwin
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor agents flow")
struct HarnessMonitorStoreAgentTuiTests {
  @Test("Start Agents sends request and selects returned snapshot")
  func startAgentTuiSendsRequestAndSelectsReturnedSnapshot() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    let started = await store.startAgentTui(
      runtime: .copilot,
      name: "Copilot TUI",
      prompt: "Investigate the latest failure.",
      rows: 30,
      cols: 110
    )
    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startAgentTui(
            sessionID: PreviewFixtures.summary.sessionId,
            runtime: "copilot",
            name: "Copilot TUI",
            prompt: "Investigate the latest failure.",
            projectDir: nil,
            persona: nil,
            argv: [],
            rows: 30,
            cols: 110
          )
        ]
    )
    #expect(store.selectedAgentTui?.runtime == "copilot")
    #expect(store.selectedAgentTui?.size == AgentTuiSize(rows: 30, cols: 110))
    #expect(store.currentSuccessFeedbackMessage == "Agents started")
  }
  @Test("Starting another Agents promotes and selects the new snapshot")
  func startAgentTuiPromotesNewSnapshotOverExistingSelection() async {
    let client = RecordingHarnessClient()
    let existing = client.agentTuiFixture(
      tuiID: "agent-tui-existing",
      runtime: AgentTuiRuntime.codex.rawValue,
      screenText: "codex> reviewing"
    )
    client.configureAgentTuis([existing], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: existing.tuiId)
    let started = await store.startAgentTui(
      runtime: .claude,
      name: "Claude TUI",
      prompt: "Inspect the active session.",
      rows: 28,
      cols: 100
    )
    #expect(started)
    #expect(store.selectedAgentTui?.tuiId == "agent-tui-2")
    #expect(store.selectedAgentTui?.runtime == AgentTuiRuntime.claude.rawValue)
    #expect(store.selectedAgentTuis.first?.tuiId == "agent-tui-2")
    #expect(store.selectedAgentTuis.contains { $0.tuiId == existing.tuiId })
  }
  @Test("Start Agents with vibe runtime sends vibe as the runtime string")
  func startAgentTuiWithVibeRuntimeSendsVibeRuntimeString() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    let started = await store.startAgentTui(
      runtime: .vibe,
      name: "Vibe TUI",
      prompt: "Run the UI spec.",
      rows: 32,
      cols: 120
    )
    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startAgentTui(
            sessionID: PreviewFixtures.summary.sessionId,
            runtime: "vibe",
            name: "Vibe TUI",
            prompt: "Run the UI spec.",
            projectDir: nil,
            persona: nil,
            argv: [],
            rows: 32,
            cols: 120
          )
        ]
    )
    #expect(store.selectedAgentTui?.runtime == "vibe")
  }
  @Test("Start Agents sends argv and project directory overrides")
  func startAgentTuiSendsArgvAndProjectDirectoryOverrides() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    let started = await store.startAgentTui(
      runtime: .claude,
      name: "Claude TUI",
      prompt: "Boot in bare mode.",
      projectDir: "  /tmp/alt-worktree  ",
      argv: ["  claude  ", "", "  --bare  "],
      rows: 24,
      cols: 90
    )
    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startAgentTui(
            sessionID: PreviewFixtures.summary.sessionId,
            runtime: "claude",
            name: "Claude TUI",
            prompt: "Boot in bare mode.",
            projectDir: "/tmp/alt-worktree",
            persona: nil,
            argv: ["claude", "--bare"],
            rows: 24,
            cols: 90
          )
        ]
    )
    #expect(store.selectedAgentTui?.argv == ["claude", "--bare"])
    #expect(store.selectedAgentTui?.projectDir == "/tmp/alt-worktree")
  }
  @Test("Agents input updates the selected screen snapshot")
  func agentTuiInputUpdatesSelectedScreenSnapshot() async {
    let client = RecordingHarnessClient()
    let tui = client.agentTuiFixture()
    client.configureAgentTuis([tui], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    let sent = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .text("status"))
    #expect(sent)
    #expect(
      client.recordedCalls()
        == [
          .sendAgentTuiInput(
            tuiID: tui.tuiId,
            request: AgentTuiInputRequest(input: .text("status"))
          )
        ]
    )
    #expect(store.selectedAgentTui?.screen.text.contains("status") == true)
  }
  @Test("Timed Agents input request replays sequence steps in order")
  func timedAgentTuiInputRequestReplaysSequenceStepsInOrder() async throws {
    let client = RecordingHarnessClient()
    let tui = client.agentTuiFixture(screenText: "copilot> ready")
    client.configureAgentTuis([tui], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    let request = try AgentTuiInputRequest(
      sequence: AgentTuiInputSequence(
        steps: [
          AgentTuiInputSequenceStep(delayBeforeMs: 0, input: .key(.enter)),
          AgentTuiInputSequenceStep(delayBeforeMs: 120, input: .control("c")),
        ]
      )
    )
    let sent = await store.sendAgentTuiInput(
      tuiID: tui.tuiId,
      request: request,
      showSuccessFeedback: false
    )
    #expect(sent)
    #expect(
      client.recordedCalls() == [.sendAgentTuiInput(tuiID: tui.tuiId, request: request)]
    )
    #expect(store.selectedAgentTui?.screen.text == "copilot> ready\n[Enter]\n[Ctrl-C]")
    #expect(store.currentSuccessFeedbackMessage == nil)
  }
  @Test("Silent Agents input skips success feedback")
  func silentAgentTuiInputSkipsSuccessFeedback() async {
    let client = RecordingHarnessClient()
    let tui = client.agentTuiFixture()
    client.configureAgentTuis([tui], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    let sent = await store.sendAgentTuiInput(
      tuiID: tui.tuiId,
      input: .key(.enter),
      showSuccessFeedback: false
    )
    #expect(sent)
    #expect(
      client.recordedCalls()
        == [
          .sendAgentTuiInput(
            tuiID: tui.tuiId,
            request: AgentTuiInputRequest(input: .key(.enter))
          )
        ]
    )
    #expect(store.currentSuccessFeedbackMessage == nil)
  }
  @Test("Agents input chases a fresher snapshot after a stale action response")
  func agentTuiInputRefreshesAfterStaleActionResponse() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture(screenText: "copilot> ready")
    let stale = client.agentTuiFixture(
      tuiID: running.tuiId,
      sessionID: running.sessionId,
      runtime: running.runtime,
      status: .running,
      rows: running.size.rows,
      cols: running.size.cols,
      screenText: "copilot> ready"
    )
    let refreshed = client.agentTuiFixture(
      tuiID: running.tuiId,
      sessionID: running.sessionId,
      runtime: running.runtime,
      status: .running,
      rows: running.size.rows,
      cols: running.size.cols,
      screenText: "copilot> ready\nstatus"
    )
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiInputResponses([stale], for: running.tuiId)
    client.configureAgentTuiReadSnapshots([refreshed], for: running.tuiId)
    let store = await selectedStore(client: client)
    let sent = await store.sendAgentTuiInput(tuiID: running.tuiId, input: .text("status"))
    #expect(sent)
    #expect(store.selectedAgentTui?.screen.text == "copilot> ready")
    try? await Task.sleep(for: .seconds(1))
    #expect(store.selectedAgentTui?.screen.text == "copilot> ready\nstatus")
  }
  @Test("Resize corrective refresh runs despite stale streaming event")
  func resizeAgentTuiCorrectiveRefreshRunsDespiteStaleStreamingEvent() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture(rows: 32, cols: 120)
    let stale = client.agentTuiFixture(
      tuiID: running.tuiId,
      sessionID: running.sessionId,
      runtime: running.runtime,
      status: .running,
      rows: 32,
      cols: 120,
      screenText: running.screen.text
    )
    let refreshed = client.agentTuiFixture(
      tuiID: running.tuiId,
      sessionID: running.sessionId,
      runtime: running.runtime,
      status: .running,
      rows: 48,
      cols: 120,
      screenText: running.screen.text
    )
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiReadSnapshots([refreshed], for: running.tuiId)
    let store = await selectedStore(client: client)
    let resized = await store.resizeAgentTui(tuiID: running.tuiId, rows: 48, cols: 120)
    #expect(resized)
    #expect(store.selectedAgentTui?.size.rows == 48)
    store.applyAgentTui(stale)
    #expect(store.selectedAgentTui?.size.rows == 32)
    try? await Task.sleep(for: .seconds(1))
    #expect(store.selectedAgentTui?.size.rows == 48)
    #expect(store.selectedAgentTuis.first?.size.rows == 48)
  }
  @Test("Silent Agents resize skips success feedback")
  func silentResizeAgentTuiSkipsSuccessFeedback() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture(rows: 32, cols: 120)
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    let resized = await store.resizeAgentTui(
      tuiID: running.tuiId,
      rows: 44,
      cols: 132,
      feedback: .silent
    )
    #expect(resized)
    #expect(
      client.recordedCalls().contains(
        .resizeAgentTui(tuiID: running.tuiId, rows: 44, cols: 132)
      )
    )
    #expect(store.selectedAgentTui?.size == AgentTuiSize(rows: 44, cols: 132))
    #expect(store.currentSuccessFeedbackMessage == nil)
  }
  @Test("Agents stream update refreshes selected TUI")
  func agentTuiStreamUpdateRefreshesSelectedTui() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture(screenText: "copilot> ready")
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    let updated = client.agentTuiFixture(
      tuiID: running.tuiId,
      status: .stopped,
      screenText: "copilot> done"
    )
    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-10T09:02:00Z",
        sessionId: PreviewFixtures.summary.sessionId,
        kind: .agentTuiUpdated(updated)
      )
    )
    #expect(store.selectedAgentTui?.tuiId == running.tuiId)
    #expect(store.selectedAgentTui?.status == .stopped)
    #expect(store.selectedAgentTui?.screen.text == "copilot> done")
  }
  @Test("Stopping Agents keeps the stopped snapshot selected")
  func stopAgentTuiKeepsStoppedSnapshotSelected() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture(screenText: "copilot> ready")
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: running.tuiId)
    let stopped = await store.stopAgentTui(tuiID: running.tuiId)
    #expect(stopped)
    #expect(client.recordedCalls().contains(.stopAgentTui(tuiID: running.tuiId)))
    #expect(store.selectedAgentTui?.tuiId == running.tuiId)
    #expect(store.selectedAgentTui?.status == .stopped)
    #expect(store.selectedAgentTuis.contains { $0.tuiId == running.tuiId && $0.status == .stopped })
  }
  @Test("Agents actions stay read-only while daemon is offline")
  func agentTuiActionsStayReadOnlyWhileDaemonIsOffline() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.connectionState = .offline("daemon down")
    let started = await store.startAgentTui(
      runtime: .copilot,
      name: nil,
      prompt: "Patch it.",
      rows: 24,
      cols: 100
    )
    #expect(started == false)
    #expect(client.recordedCalls().isEmpty)
    #expect(store.currentFailureFeedbackMessage?.contains("read-only mode") == true)
  }
  @Test("Start Agents sets unavailable flag when sandboxed daemon returns 501")
  func startAgentTuiSetsUnavailableFlagOnSandboxed501() async {
    let client = RecordingHarnessClient()
    client.configureAgentTuiStartError(
      HarnessMonitorAPIError.server(code: 501, message: "agent-tui bridge unavailable")
    )
    let store = await selectedStore(client: client)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())
    let started = await store.startAgentTui(
      runtime: .copilot,
      name: nil,
      prompt: "Test.",
      rows: 24,
      cols: 100
    )
    #expect(started == false)
    #expect(store.agentTuiUnavailable == true)
    #expect(store.currentFailureFeedbackMessage?.contains("bridge unavailable") == true)
  }
  @Test("Start Agents keeps host bridge ready when daemon is not sandboxed")
  func startAgentTuiDoesNotSetUnavailableFlagOnUnsandboxed501() async {
    let client = RecordingHarnessClient()
    client.configureAgentTuiStartError(
      HarnessMonitorAPIError.server(code: 501, message: "agent-tui bridge unavailable")
    )
    let store = await selectedStore(client: client)
    let started = await store.startAgentTui(
      runtime: .copilot,
      name: nil,
      prompt: "Test.",
      rows: 24,
      cols: 100
    )
    #expect(started == false)
    #expect(store.agentTuiUnavailable == false)
    #expect(store.currentFailureFeedbackMessage?.contains("bridge unavailable") == true)
  }
  @Test("Successful Agents start clears unavailable flag")
  func successfulAgentTuiStartClearsUnavailableFlag() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.hostBridgeCapabilityIssues["agent-tui"] = .unavailable
    let started = await store.startAgentTui(
      runtime: .copilot,
      name: nil,
      prompt: "Patch it.",
      rows: 24,
      cols: 100
    )
    #expect(started == true)
    #expect(store.agentTuiUnavailable == false)
  }

  @Test("Stale managed-agent input errors clear the dead selection without a failure toast")
  func staleManagedAgentInputErrorClearsDeadSelectionSilently() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture()
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiInputError(
      HarnessMonitorAPIError.server(
        code: 400,
        message:
          #"{"error":{"code":"KSRCLI090","message":"session not active: managed agent 'agent-tui-1' not found","details":null}}"#
      ),
      for: running.tuiId
    )
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: running.tuiId)

    let sent = await store.sendAgentTuiInput(tuiID: running.tuiId, input: .text("status"))

    #expect(sent == false)
    #expect(store.selectedAgentTui == nil)
    #expect(store.selectedAgentTuis.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Stale managed-agent refresh clears the dead selection without a failure toast")
  func staleManagedAgentRefreshClearsDeadSelectionSilently() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture()
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiReadError(
      HarnessMonitorAPIError.server(
        code: 400,
        message:
          #"{"error":{"code":"KSRCLI090","message":"session not active: managed agent 'agent-tui-1' not found","details":null}}"#
      ),
      for: running.tuiId
    )
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: running.tuiId)

    let refreshed = await store.refreshSelectedAgentTui()

    #expect(refreshed == false)
    #expect(store.selectedAgentTui == nil)
    #expect(store.selectedAgentTuis.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }
}

@MainActor
private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
  let store = await makeBootstrappedStore(client: client)
  await store.selectSession(PreviewFixtures.summary.sessionId)
  return store
}
