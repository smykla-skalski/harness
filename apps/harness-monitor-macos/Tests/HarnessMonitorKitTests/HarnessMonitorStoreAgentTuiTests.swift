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

  @Test("Start Agents accepts an explicit session when no session is selected")
  func startAgentTuiUsesExplicitSessionAnchor() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.selectedSessionID = nil
    store.selectedSession = nil

    let started = await store.startAgentTui(
      runtime: .copilot,
      name: "Copilot TUI",
      prompt: "Investigate the latest failure.",
      rows: 30,
      cols: 110,
      sessionID: PreviewFixtures.summary.sessionId
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
    #expect(store.currentFailureFeedbackMessage == nil)
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
}

@MainActor
func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
  let store = await makeBootstrappedStore(client: client)
  await store.selectSession(PreviewFixtures.summary.sessionId)
  return store
}
