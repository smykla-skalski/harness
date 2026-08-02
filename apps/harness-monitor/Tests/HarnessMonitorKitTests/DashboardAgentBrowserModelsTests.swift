import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Dashboard agent browser models")
struct DashboardAgentBrowserModelsTests {
  @Test("Selection identity round-trips arbitrary workspace and managed identifiers")
  func selectionIdentityRoundTrips() throws {
    let identity = DashboardAgentIdentity(
      workspace: DashboardAgentWorkspaceIdentity(
        projectID: "project/with spaces",
        checkoutID: "worktree:feature|agents"
      ),
      runtimeKind: .acp,
      managedAgentID: "agent/α:42"
    )

    let restored = try #require(
      DashboardAgentIdentity(selectionRawValue: identity.selectionRawValue)
    )

    #expect(restored == identity)
  }

  @Test("Runtime and workspace identity prevent matching text IDs from colliding")
  func runtimeAndWorkspaceIdentityPreventCollisions() {
    let main = workspace(projectID: "harness", checkoutID: "main")
    let feature = workspace(projectID: "harness", checkoutID: "feature")
    let agents = [
      agent(id: "shared", kind: .terminal, workspace: main, sessionID: "session-1"),
      agent(id: "shared", kind: .codex, workspace: main, sessionID: "session-1"),
      agent(id: "shared", kind: .terminal, workspace: feature, sessionID: "session-2"),
    ]

    #expect(Set(agents.map(\.identity)).count == 3)
    #expect(DashboardAgentWorkspaceGroup.make(from: agents).count == 2)
  }

  @Test("Partial refresh replaces successful workspaces and retains failed cached workspaces")
  func partialRefreshKeepsFailedWorkspaceCache() throws {
    let main = workspace(projectID: "harness", checkoutID: "main")
    let feature = workspace(projectID: "kuma", checkoutID: "feature")
    let cachedMain = agent(
      id: "main-agent",
      kind: .terminal,
      workspace: main,
      sessionID: "session-main",
      updatedAt: "2026-08-02T08:00:00Z",
      source: .cache
    )
    let cachedFeature = agent(
      id: "feature-agent",
      kind: .acp,
      workspace: feature,
      sessionID: "session-feature",
      updatedAt: "2026-08-02T08:00:00Z",
      source: .cache
    )
    let liveMain = agent(
      id: "main-agent",
      kind: .terminal,
      workspace: main,
      sessionID: "session-main",
      updatedAt: "2026-08-02T09:00:00Z",
      source: .live
    )

    let result = DashboardAgentRefreshResult.merging(
      liveAgents: [liveMain],
      cachedAgents: [cachedMain, cachedFeature],
      successfulSessionIDs: ["session-main"],
      failuresBySessionID: ["session-feature": "Timed out"]
    )

    #expect(result.source == .mixed)
    #expect(result.agents.count == 2)
    #expect(result.agents.first(where: { $0.sessionID == "session-main" })?.source == .live)
    #expect(result.agents.first(where: { $0.sessionID == "session-feature" })?.source == .cache)
    guard case .requestFailure(let message) = try #require(result.issue) else {
      Issue.record("Expected request failure")
      return
    }
    #expect(message.contains("Timed out"))
  }

  @Test("Successful empty response removes stale agents only from that workspace")
  func successfulEmptyResponseRemovesOnlyItsCache() {
    let first = agent(
      id: "first",
      kind: .terminal,
      workspace: workspace(projectID: "harness", checkoutID: "main"),
      sessionID: "session-first",
      source: .cache
    )
    let second = agent(
      id: "second",
      kind: .terminal,
      workspace: workspace(projectID: "kuma", checkoutID: "main"),
      sessionID: "session-second",
      source: .cache
    )

    let result = DashboardAgentRefreshResult.merging(
      liveAgents: [],
      cachedAgents: [first, second],
      successfulSessionIDs: ["session-first"],
      failuresBySessionID: ["session-second": "Unavailable"]
    )

    #expect(result.agents.map(\.managedAgentID) == ["second"])
  }

  @Test("Duplicate identity keeps newest summary without affecting neighboring agents")
  func duplicateIdentityKeepsNewestSummary() {
    let workspace = workspace(projectID: "harness", checkoutID: "main")
    let old = agent(
      id: "worker",
      kind: .codex,
      workspace: workspace,
      sessionID: "session",
      updatedAt: "2026-08-02T08:00:00Z"
    )
    let new = agent(
      id: "worker",
      kind: .codex,
      workspace: workspace,
      sessionID: "session",
      displayName: "Newest",
      updatedAt: "2026-08-02T09:00:00Z"
    )

    let result = DashboardAgentSummary.deduplicated([old, new])

    #expect(result.count == 1)
    #expect(result[0].displayName == "Newest")
  }
}

private func workspace(
  projectID: String,
  checkoutID: String
) -> DashboardAgentWorkspace {
  DashboardAgentWorkspace(
    identity: DashboardAgentWorkspaceIdentity(
      projectID: projectID,
      checkoutID: checkoutID
    ),
    projectName: projectID.capitalized,
    checkoutName: checkoutID,
    checkoutRoot: "/tmp/\(projectID)/\(checkoutID)"
  )
}

private func agent(
  id: String,
  kind: DashboardAgentRuntimeKind,
  workspace: DashboardAgentWorkspace,
  sessionID: String,
  displayName: String = "Agent",
  updatedAt: String = "2026-08-02T08:00:00Z",
  source: DashboardAgentDataSource = .live
) -> DashboardAgentSummary {
  DashboardAgentSummary(
    identity: DashboardAgentIdentity(
      workspace: workspace.identity,
      runtimeKind: kind,
      managedAgentID: id
    ),
    workspace: workspace,
    sessionID: sessionID,
    sessionAgentID: nil,
    displayName: displayName,
    lifecycle: .active,
    summary: "Working",
    projectDirectory: workspace.checkoutRoot,
    createdAt: "2026-08-02T07:00:00Z",
    updatedAt: updatedAt,
    source: source
  )
}
