import Foundation
import HarnessMonitorKit

@MainActor
extension DashboardAgentsPreviewFixtures {
  static let terminalAgent = liveAgents[0]
  static let stoppedTerminalAgent = terminalAgent(
    lifecycle: .stopped,
    summary: "Stopped after the release checks completed"
  )
  static let failedTerminalAgent = terminalAgent(
    lifecycle: .failed,
    summary: "The terminal process exited before it became ready"
  )

  static let stoppedTerminalState = DashboardAgentBrowserViewState(
    agents: [stoppedTerminalAgent],
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_500)
  )

  static let failedTerminalState = DashboardAgentBrowserViewState(
    agents: [failedTerminalAgent],
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_500)
  )

  static let managedTerminalDetail = DashboardTerminalAgentDetail(
    snapshot: terminalSnapshot(
      status: .running,
      text: """
        codex> Running release checks
        ✓ Dashboard agent lifecycle tests
        ✓ Monitor build and focused validation
        Waiting for snapshot approval
        """
    ),
    isMember: true,
    issues: []
  )

  static let unavailableTerminalDetail = DashboardTerminalAgentDetail(
    snapshot: nil,
    issues: [
      "Managed terminal unavailable: transport connection was lost",
      "Retry after the host bridge reconnects",
    ]
  )

  static let stoppedTerminalDetail = DashboardTerminalAgentDetail(
    snapshot: terminalSnapshot(
      status: .stopped,
      text: "codex> Release checks stopped by the operator"
    ),
    issues: []
  )

  static let failedTerminalDetail = DashboardTerminalAgentDetail(
    snapshot: terminalSnapshot(
      status: .failed,
      text: "codex> Host bridge disconnected during startup"
    ),
    issues: ["The daemon retained the failure and transcript for inspection"]
  )

  private static func terminalAgent(
    lifecycle: DashboardAgentLifecycle,
    summary: String
  ) -> DashboardAgentSummary {
    DashboardAgentSummary(
      identity: terminalAgent.identity,
      workspace: terminalAgent.workspace,
      sessionID: terminalAgent.sessionID,
      sessionAgentID: "preview-terminal-worker",
      displayName: terminalAgent.displayName,
      lifecycle: lifecycle,
      summary: summary,
      projectDirectory: terminalAgent.projectDirectory,
      createdAt: terminalAgent.createdAt,
      updatedAt: "2026-08-02T11:45:00Z",
      source: .live
    )
  }

  private static func terminalSnapshot(
    status: AgentTuiStatus,
    text: String
  ) -> AgentTuiSnapshot {
    AgentTuiPreviewSupport.snapshot(
      tuiID: terminalAgent.managedAgentID,
      spec: AgentTuiSnapshotSpec(
        agentID: "preview-terminal-worker",
        runtime: .codex,
        status: status,
        size: AgentTuiSize(rows: 32, cols: 120),
        text: text
      )
    )
  }
}
