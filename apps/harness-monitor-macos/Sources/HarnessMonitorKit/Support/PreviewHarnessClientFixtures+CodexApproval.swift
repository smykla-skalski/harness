import Foundation

extension PreviewHarnessClient.Fixtures {
  public static let codexApprovalUnification: Self = {
    let approval = CodexApprovalRequest(
      approvalId: "approval-preview-1",
      requestId: "request-preview-1",
      kind: "command",
      title: "Approve workspace write",
      detail: "Allow Codex to edit the preview worktree from the Agents window.",
      threadId: "thread-preview-1",
      turnId: "turn-preview-1",
      itemId: "item-preview-1",
      cwd: PreviewFixtures.summary.projectDir,
      command: "apply_patch",
      filePath: "Sources/HarnessMonitorUIPreviewable/Views/AgentTuiWindowView+Panes.swift"
    )
    let run = CodexRunSnapshot(
      runId: "preview-codex-approval-run",
      sessionId: PreviewFixtures.summary.sessionId,
      projectDir: PreviewFixtures.summary.projectDir ?? "/Users/example/Projects/harness",
      threadId: "thread-preview-1",
      turnId: "turn-preview-1",
      mode: .approval,
      status: .waitingApproval,
      prompt: "Review and approve the pending monitor patch",
      latestSummary: "Waiting for approval in preview",
      finalMessage: nil,
      error: nil,
      pendingApprovals: [approval],
      createdAt: "2026-04-23T08:00:00Z",
      updatedAt: "2026-04-23T08:05:00Z"
    )
    let baseFixtures = PreviewHarnessClient.Fixtures.populated
    return Self(
      health: baseFixtures.health,
      projects: baseFixtures.projects,
      sessions: baseFixtures.sessions,
      detail: baseFixtures.detail,
      timeline: baseFixtures.timeline,
      readySessionID: baseFixtures.readySessionID,
      detailsBySessionID: baseFixtures.detailsBySessionID,
      coreDetailsBySessionID: baseFixtures.coreDetailsBySessionID,
      timelinesBySessionID: baseFixtures.timelinesBySessionID,
      codexRunsBySessionID: [PreviewFixtures.summary.sessionId: [run]]
    )
  }()
}
