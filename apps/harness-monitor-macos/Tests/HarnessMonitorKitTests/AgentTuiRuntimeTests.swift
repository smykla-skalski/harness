import Testing

@testable import HarnessMonitorKit

@Suite("AgentTuiRuntime")
struct AgentTuiRuntimeTests {
  @Test("vibe raw value is vibe")
  func vibeRawValue() {
    #expect(AgentTuiRuntime.vibe.rawValue == "vibe")
  }

  @Test("vibe title is Vibe")
  func vibeTitle() {
    #expect(AgentTuiRuntime.vibe.title == "Vibe")
  }

  @Test("allCases includes vibe")
  func allCasesIncludesVibe() {
    #expect(AgentTuiRuntime.allCases.contains(.vibe))
  }

  @Test("Canonical agent TUI ordering keeps leader first regardless of updatedAt drift")
  func canonicalOrderingPrioritizesLeaderOverWorkerRefresh() {
    let leader = AgentTuiSnapshot(
      tuiId: "leader-tui",
      sessionId: "sess-ordering",
      agentId: "leader-1",
      runtime: "claude",
      status: .running,
      argv: ["claude"],
      projectDir: "/tmp/project",
      size: AgentTuiSize(rows: 24, cols: 80),
      screen: AgentTuiScreenSnapshot(rows: 24, cols: 80, cursorRow: 1, cursorCol: 1, text: ""),
      transcriptPath: "/tmp/leader.log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-12T09:00:00Z",
      updatedAt: "2026-04-12T09:01:00Z"
    )
    let worker = AgentTuiSnapshot(
      tuiId: "worker-tui",
      sessionId: "sess-ordering",
      agentId: "worker-1",
      runtime: "codex",
      status: .running,
      argv: ["codex"],
      projectDir: "/tmp/project",
      size: AgentTuiSize(rows: 24, cols: 80),
      screen: AgentTuiScreenSnapshot(rows: 24, cols: 80, cursorRow: 1, cursorCol: 1, text: ""),
      transcriptPath: "/tmp/worker.log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-12T09:02:00Z",
      updatedAt: "2026-04-12T09:10:00Z"
    )

    let ordered = AgentTuiListResponse(tuis: [worker, leader])
      .canonicallySorted(
        roleByAgent: [
          "leader-1": .leader,
          "worker-1": .worker,
        ])

    #expect(ordered.tuis.map(\.tuiId) == ["leader-tui", "worker-tui"])
  }
}
