@testable import HarnessMonitorKit

let sampleTaskBoardItemJSON: [String: JSONValue] = [
  "schema_version": .number(1),
  "id": .string("board-1"),
  "title": .string("Board item"),
  "body": .string("Body"),
  "status": .string("todo"),
  "priority": .string("high"),
  "tags": .array([]),
  "project_id": .string("harness"),
  "agent_mode": .string("interactive"),
  "external_refs": .array([]),
  "planning": .object([:]),
  "workflow": .object([
    "execution_id": .string("workflow-1"),
    "status": .string("running"),
    "current_step_id": .string("review"),
    "attempts": .number(2),
    "branch": .string("c/board-1"),
    "worktree": .string("/tmp/harness"),
    "pr_number": .number(42),
    "pr_url": .string("https://github.com/example/harness/pull/42"),
    "last_error": .null,
    "policy_trace_ids": .array([.string("trace-1")]),
  ]),
  "session_id": .string("sess-1"),
  "work_item_id": .string("task-1"),
  "usage": .object([:]),
  "created_at": .string("2026-05-14T10:00:00Z"),
  "updated_at": .string("2026-05-14T10:01:00Z"),
  "deleted_at": .null,
]

let sampleTaskBoardPositionSnapshotJSON: [String: JSONValue] = [
  "item": .object(sampleTaskBoardItemJSON),
  "item_revision": .number(7),
  "items_change_seq": .number(42),
]

let sampleTaskBoardPositionMutationJSON: [String: JSONValue] = [
  "snapshot": .object([
    "item": .object(sampleTaskBoardItemJSON),
    "item_revision": .number(8),
    "items_change_seq": .number(43),
  ]),
  "shifted": .array([
    .object([
      "item_id": .string("shifted-item"),
      "item_revision": .number(9),
    ])
  ]),
]

let sampleTaskBoardDispatchSummaryJSON: [String: JSONValue] = [
  "plans": .array([
    .object([
      "board_item_id": .string("board-1"),
      "readiness": .object([
        "state": .string("ready"),
        "reason": .null,
      ]),
      "session": .object([
        "kind": .string("existing"),
        "session_id": .string("sess-1"),
        "title": .null,
        "context": .null,
        "project_id": .string("project-1"),
      ]),
      "task": .object([
        "title": .string("Board item"),
        "context": .string("Body"),
        "severity": .string("high"),
        "suggested_fix": .string("Use the approved plan."),
        "source": .string("manual"),
        "tags": .array([.string("automation")]),
        "external_refs": .array([]),
      ]),
      "worker": .object(["mode": .string("interactive")]),
      "reviewer": .object([
        "phase": .string("after_worker_review"),
        "suggested_persona": .string("reviewer"),
        "required_consensus": .number(1),
      ]),
      "evaluator": .object([
        "phase": .string("after_worker_review"),
        "mode": .string("evaluate"),
      ]),
      "policy": .object([
        "decision": .string("allow"),
        "reason_code": .string("default_allow"),
        "policy_version": .string("task-board-policy-v1"),
      ]),
    ])
  ]),
  "applied": .array([
    .object([
      "board_item_id": .string("board-1"),
      "session_id": .string("sess-1"),
      "work_item_id": .string("task-1"),
      "item": .object(sampleTaskBoardItemJSON),
    ])
  ]),
]

let sampleTaskBoardEvaluationSummaryJSON: [String: JSONValue] = [
  "total": .number(1),
  "evaluated": .number(1),
  "updated": .number(1),
  "skipped": .number(0),
  "completed": .number(1),
  "running": .number(0),
  "reviewing": .number(0),
  "blocked": .number(0),
  "failed": .number(0),
  "records": .array([
    .object([
      "board_item_id": .string("board-1"),
      "session_id": .string("sess-1"),
      "work_item_id": .string("task-1"),
      "outcome": .string("completed"),
      "task_status": .string("done"),
      "board_status": .string("done"),
      "workflow_status": .string("completed"),
      "updated": .bool(true),
      "reason": .null,
      "item": .object(sampleTaskBoardItemJSON),
    ])
  ]),
]

let sampleTaskBoardSyncSummaryJSON: [String: JSONValue] = [
  "total": .number(1),
  "providers": .array([
    .object([
      "provider": .string("github"),
      "configured": .bool(true),
      "linked": .number(1),
      "pushable": .number(0),
      "blocked": .number(0),
      "token_env": .array([.string("HARNESS_GITHUB_TOKEN"), .string("GH_TOKEN")]),
    ])
  ]),
  "operations": .array([
    .object([
      "provider": .string("github"),
      "action": .string("push"),
      "board_item_id": .string("board-1"),
      "external_id": .string("123"),
      "url": .string("https://example.invalid/issues/123"),
      "dry_run": .bool(false),
      "applied": .bool(true),
    ])
  ]),
]

let sampleTaskBoardPlanningResponseJSON: [String: JSONValue] = [
  "transition": .object([
    "board_item_id": .string("board-1"),
    "from_status": .string("planning"),
    "to_status": .string("agentic_review"),
    "planning": .object([
      "summary": .string("Use the semantic plan."),
      "approved_by": .null,
      "approved_at": .null,
    ]),
  ]),
  "item": .object(sampleTaskBoardItemJSON),
]

let sampleTaskBoardOrchestratorSettingsJSON: [String: JSONValue] = [
  "enabled_workflows": .array([
    .string("default_task"),
    .string("pr_fix"),
    .string("pr_review"),
    .string("review"),
  ]),
  "dry_run_default": .bool(false),
  "dispatch_status_filter": .string("todo"),
  "project_dir": .string("/tmp/harness"),
  "github_project": .object([
    "owner": .string("example"),
    "repo": .string("harness"),
    "checkout_path": .string("/tmp/harness"),
    "default_branch": .string("main"),
    "branch_prefix": .string("c/"),
    "merge_method": .string("squash"),
    "labels": .object([
      "managed": .string("harness:managed"),
      "auto_merge": .string("harness:auto-merge"),
      "needs_human": .string("harness:needs-human"),
      "protected_path": .string("harness:protected-path"),
    ]),
    "protected_paths": .array([.object(["pattern": .string("apps/harness-monitor")])]),
    "enabled_automations": .object([
      "enabled": .array([
        .string("sync_task_board"),
        .string("create_branch"),
        .string("open_pull_request"),
        .string("watch_checks"),
        .string("request_review"),
        .string("auto_merge"),
      ])
    ]),
  ]),
  "github_inbox": .object([
    "repositories": .array([.string("example/harness"), .string("example/aff")])
  ]),
  "policy_version": .string("task-board-policy-v2"),
]

let sampleTaskBoardOrchestratorStatusJSON: [String: JSONValue] = [
  "enabled": .bool(true),
  "running": .bool(false),
  "current_tick": .object([
    "run_id": .string("run-active"),
    "phase": .string("evaluation"),
    "started_at": .string("2026-05-14T10:02:00Z"),
    "completed_at": .null,
    "dry_run": .bool(false),
  ]),
  "last_run": .object([
    "run_id": .string("run-1"),
    "status": .string("completed"),
    "started_at": .string("2026-05-14T10:00:00Z"),
    "completed_at": .string("2026-05-14T10:01:00Z"),
    "dry_run": .bool(false),
    "sync": .object(sampleTaskBoardSyncSummaryJSON),
    "audit": .object([
      "total": .number(1),
      "ready": .number(1),
      "blocked": .number(0),
      "deleted": .number(0),
      "by_status": .array([]),
    ]),
    "dispatch": .object(sampleTaskBoardDispatchSummaryJSON),
    "evaluation": .object(sampleTaskBoardEvaluationSummaryJSON),
    "error": .null,
    "policy_trace_ids": .array([.string("trace-1")]),
  ]),
  "workflow_execution_counts": .array([
    .object(["status": .string("completed"), "count": .number(3)]),
    .object(["status": .string("failed"), "count": .number(1)]),
  ]),
  "settings": .object(sampleTaskBoardOrchestratorSettingsJSON),
]

let sampleTaskBoardOrchestratorRunOnceJSON = sampleTaskBoardOrchestratorStatusJSON

let sampleTaskBoardGitRuntimeConfigJSON: [String: JSONValue] = [
  "global": .object([
    "author_name": .string("Harness Bot"),
    "author_email": .string("bot@example.com"),
    "ssh_key_path": .string("/Users/test/.ssh/id_ed25519"),
    "signing": .object([
      "mode": .string("ssh"),
      "ssh_key_path": .string("/Users/test/.ssh/id_signing"),
      "gpg_key_id": .null,
    ]),
  ]),
  "repository_overrides": .array([
    .object([
      "repository": .string("example/harness"),
      "profile": .object([
        "author_name": .string("Repo Bot"),
        "author_email": .string("repo@example.com"),
        "ssh_key_path": .string("/Users/test/.ssh/id_repo"),
        "signing": .object([
          "mode": .string("gpg"),
          "ssh_key_path": .null,
          "gpg_key_id": .string("ABC123"),
        ]),
      ]),
    ])
  ]),
]

let sampleGitHubTokensSyncJSON: [String: JSONValue] = [
  "global_token_configured": .bool(true),
  "repository_token_count": .number(1),
]

let sampleTodoistTokenSyncJSON: [String: JSONValue] = [
  "token_configured": .bool(true)
]
