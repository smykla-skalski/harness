import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Agents window pending user prompt")
@MainActor
struct AgentsWindowPendingUserPromptTests {
  @Test("Resolves pending user prompt for the selected terminal agent")
  func resolvesPendingUserPromptForSelectedTerminalAgent() {
    let prompt = AgentPendingUserPrompt(
      toolName: "AskUserQuestion",
      waitingSince: "2026-04-28T08:00:00Z",
      questions: [
        AgentPendingUserPromptQuestion(
          question: "Approve the file write?",
          header: "Approval",
          options: [
            AgentPendingUserPromptOption(label: "Allow", description: "Proceed"),
            AgentPendingUserPromptOption(label: "Deny", description: "Stop"),
          ]
        )
      ]
    )
    let activity = AgentToolActivitySummary(
      agentId: "agent-alpha",
      runtime: "claude",
      toolInvocationCount: 1,
      toolResultCount: 0,
      toolErrorCount: 0,
      latestToolName: "AskUserQuestion",
      latestEventAt: "2026-04-28T08:00:00Z",
      recentTools: ["AskUserQuestion"],
      pendingUserPrompt: prompt
    )

    let resolved = AgentsWindowView.pendingUserPrompt(
      for: makeTuiSnapshot(agentID: "agent-alpha"),
      session: PreviewFixtures.sessionDetail(
        session: PreviewFixtures.summary,
        agents: [makeAgent(id: "agent-alpha", name: "Alpha")],
        agentActivity: [activity]
      )
    )

    #expect(resolved == prompt)
  }

  @Test("Ignores prompts belonging to a different agent")
  func ignoresPromptForDifferentAgent() {
    let activity = AgentToolActivitySummary(
      agentId: "agent-bravo",
      runtime: "claude",
      toolInvocationCount: 1,
      toolResultCount: 0,
      toolErrorCount: 0,
      latestToolName: "AskUserQuestion",
      latestEventAt: "2026-04-28T08:00:00Z",
      recentTools: ["AskUserQuestion"],
      pendingUserPrompt: AgentPendingUserPrompt(
        toolName: "AskUserQuestion",
        questions: [
          AgentPendingUserPromptQuestion(
            question: "Approve the file write?",
            options: [AgentPendingUserPromptOption(label: "Allow")]
          )
        ]
      )
    )

    let resolved = AgentsWindowView.pendingUserPrompt(
      for: makeTuiSnapshot(agentID: "agent-alpha"),
      session: PreviewFixtures.sessionDetail(
        session: PreviewFixtures.summary,
        agents: [
          makeAgent(id: "agent-alpha", name: "Alpha"),
          makeAgent(id: "agent-bravo", name: "Bravo"),
        ],
        agentActivity: [activity]
      )
    )

    #expect(resolved == nil)
  }

  private func makeAgent(id: String, name: String) -> AgentRegistration {
    AgentRegistration(
      agentId: id,
      name: name,
      runtime: "claude",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 1,
        hookPoints: []
      ),
      persona: nil
    )
  }

  private func makeTuiSnapshot(agentID: String) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: "tui-\(agentID)",
      sessionId: PreviewFixtures.summary.sessionId,
      agentId: agentID,
      runtime: "claude",
      status: .running,
      argv: ["claude"],
      projectDir: "/tmp/fixture",
      size: AgentTuiSize(rows: 24, cols: 80),
      screen: AgentTuiScreenSnapshot(rows: 24, cols: 80, cursorRow: 1, cursorCol: 1, text: ""),
      transcriptPath: "/tmp/\(agentID).log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z"
    )
  }
}
