import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard agent navigation resolver")
struct DashboardAgentNavigationResolverTests {
  @Test("Session, session-agent, and managed targets resolve without identity guessing")
  func agentTargetsResolveExactly() throws {
    let terminal = navigationAgent(
      managedID: "terminal-1",
      sessionAgentID: "worker-1",
      kind: .terminal
    )
    let codex = navigationAgent(
      managedID: "codex-1",
      sessionAgentID: "worker-2",
      kind: .codex
    )
    let agents = [terminal, codex]

    #expect(
      DashboardAgentNavigationResolver.selection(
        for: .session(sessionID: "session-1"),
        agents: agents,
        decisions: .empty
      ) == .agent(terminal.identity)
    )
    #expect(
      DashboardAgentNavigationResolver.selection(
        for: .sessionAgent(sessionID: "session-1", agentID: "worker-2"),
        agents: agents,
        decisions: .empty
      ) == .agent(codex.identity)
    )
    #expect(
      DashboardAgentNavigationResolver.selection(
        for: .managedAgent(
          sessionID: "session-1",
          runtimeKind: .terminal,
          managedAgentID: "terminal-1"
        ),
        agents: agents,
        decisions: .empty
      ) == .agent(terminal.identity)
    )
  }

  @Test("Decision targets preserve agent, workspace, and global destinations")
  func decisionTargetsResolveExactly() {
    let agent = navigationAgent(
      managedID: "terminal-1",
      sessionAgentID: "worker-1",
      kind: .terminal
    )
    let workspace = agent.workspace
    let resolution = DashboardDecisionResolution(
      allItems: [
        navigationDecision(
          id: "agent-decision",
          target: .agent(agent.identity),
          workspace: workspace
        ),
        navigationDecision(
          id: "workspace-decision",
          target: .workspace(workspace.identity),
          workspace: workspace
        ),
        navigationDecision(id: "global-decision", target: .unattributed, workspace: nil),
      ],
      itemsByAgent: [:],
      summaryByAgent: [:],
      workspaceBuckets: [],
      unattributedItems: []
    )

    #expect(
      DashboardAgentNavigationResolver.selection(
        for: .decision(decisionID: "agent-decision"),
        agents: [agent],
        decisions: resolution
      ) == .agent(agent.identity)
    )
    #expect(
      DashboardAgentNavigationResolver.selection(
        for: .decision(decisionID: "workspace-decision"),
        agents: [agent],
        decisions: resolution
      ) == .workspaceDecisions(workspace.identity)
    )
    #expect(
      DashboardAgentNavigationResolver.selection(
        for: .decision(decisionID: "global-decision"),
        agents: [agent],
        decisions: resolution
      ) == .globalDecisions
    )
  }

  @Test("Stale targets do not silently select a different agent")
  func staleTargetIsUnavailable() {
    let agent = navigationAgent(
      managedID: "terminal-1",
      sessionAgentID: "worker-1",
      kind: .terminal
    )

    #expect(
      DashboardAgentNavigationResolver.selection(
        for: .managedAgent(
          sessionID: "session-1",
          runtimeKind: .terminal,
          managedAgentID: "missing"
        ),
        agents: [agent],
        decisions: .empty
      ) == nil
    )
  }

  @Test("Decision navigation waits for one decision refresh before reporting unavailable")
  func decisionNavigationWaitsForDecisionRefresh() {
    let readiness = DashboardDecisionNavigationReadiness(
      requestID: 7,
      initialRefreshTick: 3
    )

    #expect(!readiness.canReportUnavailable(currentRefreshTick: 3))
    #expect(readiness.canReportUnavailable(currentRefreshTick: 4))
  }
}

private func navigationAgent(
  managedID: String,
  sessionAgentID: String,
  kind: DashboardAgentRuntimeKind
) -> DashboardAgentSummary {
  let workspace = DashboardAgentWorkspace(
    identity: .init(projectID: "harness", checkoutID: "main"),
    projectName: "Harness",
    checkoutName: "main",
    checkoutRoot: "/tmp/harness"
  )
  return DashboardAgentSummary(
    identity: .init(
      workspace: workspace.identity,
      runtimeKind: kind,
      managedAgentID: managedID
    ),
    workspace: workspace,
    sessionID: "session-1",
    sessionAgentID: sessionAgentID,
    displayName: managedID,
    lifecycle: .active,
    summary: nil,
    projectDirectory: workspace.checkoutRoot,
    createdAt: "2026-08-05T00:00:00Z",
    updatedAt: "2026-08-05T00:00:00Z",
    source: .live
  )
}

private func navigationDecision(
  id: String,
  target: DashboardDecisionTarget,
  workspace: DashboardAgentWorkspace?
) -> DashboardDecisionItem {
  DashboardDecisionItem(
    id: id,
    ruleID: "manual-session-window",
    kind: .manual,
    severity: .needsUser,
    summary: "Decision",
    createdAt: .distantPast,
    target: target,
    workspace: workspace
  )
}
