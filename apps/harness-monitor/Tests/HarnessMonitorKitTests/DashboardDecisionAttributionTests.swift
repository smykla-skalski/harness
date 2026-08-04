import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Dashboard decision attribution")
struct DashboardDecisionAttributionTests {
  @Test("Kind is derived from the persisted rule id")
  func kindDerivation() {
    #expect(DashboardDecisionKind(ruleID: "acp-permission") == .acpPermission)
    #expect(DashboardDecisionKind(ruleID: "codex-approval") == .codexApproval)
    #expect(DashboardDecisionKind(ruleID: "manual-session-window") == .manual)
    #expect(DashboardDecisionKind(ruleID: "stuck-agent") == .supervisor)
  }

  @Test("ACP permission decision attaches to its managed agent")
  func acpAttachesToAgent() {
    let ws = workspace(projectID: "harness", checkoutID: "main")
    let managed = agentSummary(
      managedID: "acp-7",
      kind: .acp,
      workspace: ws,
      sessionID: "s1",
      sessionAgentID: "sa-1"
    )
    let decision = AttributionInputFixture(
      id: "acp-permission:b1",
      ruleID: "acp-permission",
      severity: .warn,
      sessionID: "s1",
      sessionAgentID: "sa-1",
      managedAgentID: "acp-7",
      workspace: ws
    ).input

    let resolution = DashboardDecisionAttributor.resolve(inputs: [decision], agents: [managed])

    #expect(resolution.itemsByAgent[managed.identity]?.count == 1)
    #expect(resolution.itemsByAgent[managed.identity]?.first?.target == .agent(managed.identity))
    #expect(resolution.summaryByAgent[managed.identity]?.count == 1)
    #expect(resolution.summaryByAgent[managed.identity]?.worstSeverity == .warn)
    #expect(resolution.workspaceBuckets.isEmpty)
  }

  @Test("Supervisor decision with a session agent attaches to that agent")
  func supervisorAttachesBySessionAgent() {
    let ws = workspace(projectID: "harness", checkoutID: "main")
    let managed = agentSummary(
      managedID: "codex-3",
      kind: .codex,
      workspace: ws,
      sessionID: "s1",
      sessionAgentID: "sa-9"
    )
    let decision = AttributionInputFixture(
      id: "stuck-agent:1",
      ruleID: "stuck-agent",
      severity: .critical,
      sessionID: "s1",
      sessionAgentID: "sa-9",
      managedAgentID: nil,
      workspace: ws
    ).input

    let resolution = DashboardDecisionAttributor.resolve(inputs: [decision], agents: [managed])

    #expect(resolution.itemsByAgent[managed.identity]?.first?.target == .agent(managed.identity))
    #expect(resolution.summaryByAgent[managed.identity]?.worstSeverity == .critical)
  }

  @Test("Task-scoped decision with no agent becomes a work item in its workspace bucket")
  func taskScopedBucket() {
    let ws = workspace(projectID: "harness", checkoutID: "feature")
    let decision = AttributionInputFixture(
      id: "unassigned-task:1",
      ruleID: "unassigned-task",
      severity: .needsUser,
      sessionID: "s2",
      sessionAgentID: nil,
      taskID: "task-42",
      managedAgentID: nil,
      workspace: ws
    ).input

    let resolution = DashboardDecisionAttributor.resolve(inputs: [decision], agents: [])

    #expect(resolution.itemsByAgent.isEmpty)
    let bucket = resolution.workspaceBuckets.first
    #expect(bucket?.workspace.identity == ws.identity)
    #expect(bucket?.items.first?.target == .workItem(workspace: ws.identity, taskID: "task-42"))
  }

  @Test("Session-only decision with no agent or task becomes a workspace target")
  func workspaceScoped() {
    let ws = workspace(projectID: "harness", checkoutID: "main")
    let decision = AttributionInputFixture(
      id: "daemon-disconnect",
      ruleID: "daemon-disconnect",
      severity: .critical,
      sessionID: "s3",
      sessionAgentID: nil,
      managedAgentID: nil,
      workspace: ws
    ).input

    let resolution = DashboardDecisionAttributor.resolve(inputs: [decision], agents: [])

    #expect(resolution.workspaceBuckets.first?.items.first?.target == .workspace(ws.identity))
  }

  @Test("Decision whose managed agent is not loaded falls back to its workspace bucket")
  func unloadedAgentFallsBackToWorkspace() {
    let ws = workspace(projectID: "harness", checkoutID: "main")
    let decision = AttributionInputFixture(
      id: "acp-permission:b2",
      ruleID: "acp-permission",
      severity: .warn,
      sessionID: "s1",
      sessionAgentID: "sa-x",
      managedAgentID: "acp-unloaded",
      workspace: ws
    ).input

    let resolution = DashboardDecisionAttributor.resolve(inputs: [decision], agents: [])

    #expect(resolution.itemsByAgent.isEmpty)
    #expect(resolution.workspaceBuckets.first?.workspace.identity == ws.identity)
  }

  @Test("Decision with no resolvable workspace is unattributed")
  func unattributed() {
    let decision = AttributionInputFixture(
      id: "x",
      ruleID: "idle-session",
      severity: .info,
      sessionID: nil,
      sessionAgentID: nil,
      managedAgentID: nil,
      workspace: nil
    ).input

    let resolution = DashboardDecisionAttributor.resolve(inputs: [decision], agents: [])

    #expect(resolution.unattributedItems.count == 1)
    #expect(resolution.workspaceBuckets.isEmpty)
    #expect(resolution.hasDecisionDestinations)
  }

  @Test("Worst severity and ordering reflect the highest-rank decision for an agent")
  func worstSeverityAggregates() {
    let ws = workspace(projectID: "harness", checkoutID: "main")
    let managed = agentSummary(
      managedID: "acp-7",
      kind: .acp,
      workspace: ws,
      sessionID: "s1",
      sessionAgentID: "sa-1"
    )
    let warn = AttributionInputFixture(
      id: "d1",
      ruleID: "acp-permission",
      severity: .warn,
      sessionID: "s1",
      sessionAgentID: "sa-1",
      managedAgentID: "acp-7",
      workspace: ws
    ).input
    let critical = AttributionInputFixture(
      id: "d2",
      ruleID: "stuck-agent",
      severity: .critical,
      sessionID: "s1",
      sessionAgentID: "sa-1",
      managedAgentID: nil,
      workspace: ws
    ).input

    let resolution = DashboardDecisionAttributor.resolve(
      inputs: [warn, critical],
      agents: [managed]
    )

    #expect(resolution.summaryByAgent[managed.identity]?.count == 2)
    #expect(resolution.summaryByAgent[managed.identity]?.worstSeverity == .critical)
    #expect(resolution.itemsByAgent[managed.identity]?.map(\.id) == ["d2", "d1"])
  }
}

private func workspace(
  projectID: String,
  checkoutID: String
) -> DashboardAgentWorkspace {
  DashboardAgentWorkspace(
    identity: DashboardAgentWorkspaceIdentity(projectID: projectID, checkoutID: checkoutID),
    projectName: projectID.capitalized,
    checkoutName: checkoutID,
    checkoutRoot: "/tmp/\(projectID)/\(checkoutID)"
  )
}

private func agentSummary(
  managedID: String,
  kind: DashboardAgentRuntimeKind,
  workspace: DashboardAgentWorkspace,
  sessionID: String,
  sessionAgentID: String?
) -> DashboardAgentSummary {
  DashboardAgentSummary(
    identity: DashboardAgentIdentity(
      workspace: workspace.identity,
      runtimeKind: kind,
      managedAgentID: managedID
    ),
    workspace: workspace,
    sessionID: sessionID,
    sessionAgentID: sessionAgentID,
    displayName: managedID,
    lifecycle: .active,
    summary: nil,
    projectDirectory: workspace.checkoutRoot,
    createdAt: "2026-08-02T07:00:00Z",
    updatedAt: "2026-08-02T08:00:00Z",
    source: .live
  )
}

private struct AttributionInputFixture {
  let id: String
  let ruleID: String
  let severity: DecisionSeverity
  let sessionID: String?
  let sessionAgentID: String?
  var taskID: String?
  let managedAgentID: String?
  let workspace: DashboardAgentWorkspace?

  var input: DashboardDecisionAttributionInput {
    DashboardDecisionAttributionInput(
      id: id,
      ruleID: ruleID,
      severity: severity,
      summary: id,
      createdAt: Date(timeIntervalSince1970: 1_000),
      sessionID: sessionID,
      sessionAgentID: sessionAgentID,
      taskID: taskID,
      managedAgentID: managedAgentID,
      managedAgentKind: managedAgentKind(for: ruleID),
      workspace: workspace
    )
  }
}

private func managedAgentKind(for ruleID: String) -> DashboardAgentRuntimeKind? {
  switch ruleID {
  case "acp-permission": .acp
  case "codex-approval": .codex
  default: nil
  }
}
