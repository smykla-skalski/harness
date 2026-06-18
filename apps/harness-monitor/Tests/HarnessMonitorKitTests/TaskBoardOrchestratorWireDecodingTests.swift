import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the orchestrator settings + status tree (orchestratorStatus/start/
/// stop/run-once + settings get/update). Generated from orchestrator/types.rs; the settings reuse
/// the GitHubProjectConfig sub-tree wire (TYPE_RENAMES on the Rust alias) and the run summary nests
/// the sync/audit summary wires. enabled_workflows, dispatch_status_filter, phase, status and the
/// workflow-execution status ride bare through the decoder-agnostic hand enums.
@Suite("Task board orchestrator wire decoding")
struct TaskBoardOrchestratorWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  private let githubProjectJSON = #"""
    {
      "owner": "acme", "repo": "widget", "checkout_path": "/checkouts/widget",
      "default_branch": "main", "branch_prefix": "c/", "merge_method": "rebase",
      "labels": {"managed": "m", "auto_merge": "am", "needs_human": "nh", "protected_path": "pp"},
      "protected_paths": [{"pattern": "src/**"}],
      "requested_reviewers": {"reviewers": ["r1"], "team_reviewers": ["t1"]},
      "enabled_automations": {"enabled": ["sync_task_board", "create_branch"]}
    }
    """#

  @Test("settings maps the workflows, inbox configs and the nested github project tree")
  func settingsMapping() throws {
    let payload = #"""
      {
        "enabled_workflows": ["default_task", "pr_fix", "pr_review", "review"],
        "dry_run_default": false,
        "dispatch_status_filter": "todo",
        "project_dir": "/work/proj",
        "github_project": \#(githubProjectJSON),
        "github_inbox": {"repositories": ["acme/widget"], "label_filter": ["bug"]},
        "todoist_inbox": {"project_filter": ["Inbox"]},
        "policy_version": "task-board-policy-v1"
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(TaskBoardOrchestratorSettingsWire.self, from: data)
    let settings = TaskBoardOrchestratorSettings(wire: wire)

    #expect(settings.enabledWorkflows == [.defaultTask, .prFix, .prReview, .review])
    #expect(settings.dryRunDefault == false)
    #expect(settings.dispatchStatusFilter == .todo)
    #expect(settings.projectDir == "/work/proj")
    #expect(settings.githubProject.owner == "acme")
    #expect(settings.githubProject.checkoutPath == "/checkouts/widget")
    #expect(settings.githubInbox.repositories == ["acme/widget"])
    #expect(settings.githubInbox.labelFilter == ["bug"])
    #expect(settings.todoistInbox.projectFilter == ["Inbox"])
    #expect(settings.policyVersion == "task-board-policy-v1")
  }

  @Test("status maps the tick, run summary and workflow counts including the bare enums")
  func statusMappingWithRun() throws {
    let payload = #"""
      {
        "enabled": true,
        "running": true,
        "current_tick": {
          "run_id": "r1", "phase": "dispatch", "started_at": "2026-06-18T00:00:00Z",
          "completed_at": null, "dry_run": true
        },
        "last_run": {
          "run_id": "r0", "started_at": "2026-06-18T00:00:00Z",
          "completed_at": "2026-06-18T00:01:00Z", "status": "completed", "dry_run": false,
          "sync": {"total": 0, "providers": [], "operations": []},
          "audit": {"total": 2, "ready": 1, "blocked": 0, "deleted": 0, "by_status": []},
          "dispatch": null, "evaluation": null, "error": null, "policy_trace_ids": ["t1", "t2"]
        },
        "workflow_execution_counts": [
          {"status": "running", "count": 3},
          {"status": "completed", "count": 7}
        ],
        "settings": {
          "enabled_workflows": ["default_task"],
          "dry_run_default": true,
          "github_project": \#(githubProjectJSON),
          "policy_version": "task-board-policy-v1"
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(TaskBoardOrchestratorStatusWire.self, from: data)
    let status = TaskBoardOrchestratorStatus(wire: wire)

    #expect(status.enabled)
    #expect(status.running)
    #expect(status.currentTick?.phase == .dispatch)
    #expect(status.currentTick?.completedAt == nil)
    #expect(status.lastRun?.status == .completed)
    #expect(status.lastRun?.audit.total == 2)
    #expect(status.lastRun?.dispatch == nil)
    #expect(status.lastRun?.policyTraceIds == ["t1", "t2"])
    #expect(status.workflowExecutionCounts.map(\.status) == [.running, .completed])
    #expect(status.workflowExecutionCounts.map(\.count) == [3, 7])
    #expect(status.settings.enabledWorkflows == [.defaultTask])
    #expect(status.settings.githubProject.repo == "widget")
  }
}
