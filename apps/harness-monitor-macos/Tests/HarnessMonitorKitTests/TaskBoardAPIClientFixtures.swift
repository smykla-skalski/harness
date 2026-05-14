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
  "session_id": .string("sess-1"),
  "work_item_id": .string("task-1"),
  "usage": .object([:]),
  "created_at": .string("2026-05-14T10:00:00Z"),
  "updated_at": .string("2026-05-14T10:01:00Z"),
  "deleted_at": .null,
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
      "provider": .string("git_hub"),
      "configured": .bool(true),
      "linked": .number(1),
      "pushable": .number(0),
      "blocked": .number(0),
      "token_env": .array([.string("HARNESS_GITHUB_TOKEN"), .string("GH_TOKEN")]),
    ])
  ]),
  "operations": .array([
    .object([
      "provider": .string("git_hub"),
      "action": .string("push"),
      "board_item_id": .string("board-1"),
      "external_id": .string("123"),
      "url": .string("https://example.invalid/issues/123"),
      "dry_run": .bool(false),
      "applied": .bool(true),
    ])
  ]),
]

let sampleTaskBoardOrchestratorSettingsJSON: [String: JSONValue] = [
  "enabled_workflows": .array([
    .string("default_task"),
    .string("pr_fix"),
    .string("pr_review"),
    .string("dependency_update"),
  ]),
  "dry_run_default": .bool(false),
  "dispatch_status_filter": .string("todo"),
  "project_dir": .string("/tmp/harness"),
  "github_project": .object([
    "owner": .string("kong"),
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
    "protected_paths": .array([.object(["pattern": .string("apps/harness-monitor-macos")])]),
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

let sampleTaskBoardItemJSONString =
  """
  {
    "schema_version": 1,
    "id": "board-1",
    "title": "Board item",
    "body": "Body",
    "status": "todo",
    "priority": "high",
    "tags": [],
    "project_id": "harness",
    "agent_mode": "interactive",
    "external_refs": [],
    "planning": {},
    "session_id": "sess-1",
    "work_item_id": "task-1",
    "usage": {},
    "created_at": "2026-05-14T10:00:00Z",
    "updated_at": "2026-05-14T10:01:00Z",
    "deleted_at": null
  }
  """

let sampleTaskBoardEvaluationSummaryText =
  """
  {
    "total": 1,
    "evaluated": 1,
    "updated": 1,
    "skipped": 0,
    "completed": 1,
    "running": 0,
    "reviewing": 0,
    "blocked": 0,
    "failed": 0,
    "records": [
      {
        "board_item_id": "board-1",
        "session_id": "sess-1",
        "work_item_id": "task-1",
        "outcome": "completed",
        "task_status": "done",
        "board_status": "done",
        "workflow_status": "completed",
        "updated": true,
        "reason": null,
        "item": \(sampleTaskBoardItemJSONString)
      }
    ]
  }
  """

let sampleOrchestratorSettingsText =
  """
  {
    "enabled_workflows": ["default_task", "pr_fix", "pr_review", "dependency_update"],
    "dry_run_default": false,
    "dispatch_status_filter": "todo",
    "project_dir": "/tmp/harness",
    "github_project": {
      "owner": "kong",
      "repo": "harness",
      "checkout_path": "/tmp/harness",
      "default_branch": "main",
      "branch_prefix": "c/",
      "merge_method": "squash",
      "labels": {
        "managed": "harness:managed",
        "auto_merge": "harness:auto-merge",
        "needs_human": "harness:needs-human",
        "protected_path": "harness:protected-path"
      },
      "protected_paths": [
        { "pattern": "apps/harness-monitor-macos" }
      ],
      "enabled_automations": {
        "enabled": [
          "sync_task_board",
          "create_branch",
          "open_pull_request",
          "watch_checks",
          "request_review",
          "auto_merge"
        ]
      }
    },
    "policy_version": "task-board-policy-v2"
  }
  """

let sampleTaskBoardSyncSummaryText =
  """
  {
    "total": 1,
    "providers": [
      {
        "provider": "git_hub",
        "configured": true,
        "linked": 1,
        "pushable": 0,
        "blocked": 0,
        "token_env": ["HARNESS_GITHUB_TOKEN", "GH_TOKEN"]
      }
    ],
    "operations": [
      {
        "provider": "git_hub",
        "action": "push",
        "board_item_id": "board-1",
        "external_id": "123",
        "url": "https://example.invalid/issues/123",
        "dry_run": false,
        "applied": true
      }
    ]
  }
  """

let sampleOrchestratorStatusText =
  """
  {
    "enabled": true,
    "running": false,
    "current_tick": {
      "run_id": "run-active",
      "phase": "evaluation",
      "started_at": "2026-05-14T10:02:00Z",
      "completed_at": null,
      "dry_run": false
    },
    "last_run": {
      "run_id": "run-1",
      "status": "completed",
      "started_at": "2026-05-14T10:00:00Z",
      "completed_at": "2026-05-14T10:01:00Z",
      "dry_run": false,
      "sync": \(sampleTaskBoardSyncSummaryText),
      "audit": {
        "total": 1,
        "ready": 1,
        "blocked": 0,
        "deleted": 0,
        "by_status": []
      },
      "dispatch": \(sampleTaskBoardDispatchSummaryJSONString),
      "evaluation": \(sampleTaskBoardEvaluationSummaryText),
      "error": null,
      "policy_trace_ids": ["trace-1"]
    },
    "workflow_execution_counts": [
      { "status": "completed", "count": 3 },
      { "status": "failed", "count": 1 }
    ],
    "settings": \(sampleOrchestratorSettingsText)
  }
  """

let sampleTaskBoardDispatchSummaryJSONString =
  """
  {
    "plans": [
      {
        "board_item_id": "board-1",
        "readiness": { "state": "ready", "reason": null },
        "session": {
          "kind": "existing",
          "session_id": "sess-1",
          "title": null,
          "context": null,
          "project_id": "project-1"
        },
        "task": {
          "title": "Board item",
          "context": "Body",
          "severity": "high",
          "suggested_fix": "Use the approved plan.",
          "source": "manual",
          "tags": ["automation"],
          "external_refs": []
        },
        "worker": { "mode": "interactive" },
        "reviewer": {
          "phase": "after_worker_review",
          "suggested_persona": "reviewer",
          "required_consensus": 1
        },
        "evaluator": { "phase": "after_worker_review", "mode": "evaluate" },
        "policy": {
          "decision": "allow",
          "reason_code": "default_allow",
          "policy_version": "task-board-policy-v1"
        }
      }
    ],
    "applied": [
      {
        "board_item_id": "board-1",
        "session_id": "sess-1",
        "work_item_id": "task-1",
        "item": \(sampleTaskBoardItemJSONString)
      }
    ]
  }
  """

let sampleOrchestratorRunOnceText =
  sampleOrchestratorStatusText
