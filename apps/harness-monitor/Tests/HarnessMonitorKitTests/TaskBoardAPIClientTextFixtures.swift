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
    "workflow": {
      "execution_id": "workflow-1",
      "status": "running",
      "current_step_id": "review",
      "attempts": 2,
      "branch": "c/board-1",
      "worktree": "/tmp/harness",
      "pr_number": 42,
      "pr_url": "https://github.com/example/harness/pull/42",
      "last_error": null,
      "policy_trace_ids": ["trace-1"]
    },
    "session_id": "sess-1",
    "work_item_id": "task-1",
    "usage": {},
    "created_at": "2026-05-14T10:00:00Z",
    "updated_at": "2026-05-14T10:01:00Z",
    "deleted_at": null
  }
  """

let sampleTaskBoardPositionSnapshotText =
  """
  {"item": \(sampleTaskBoardItemJSONString), "item_revision": 7, "items_change_seq": 42}
  """

let sampleTaskBoardPositionMutationText =
  """
  {
    "snapshot": {
      "item": \(sampleTaskBoardItemJSONString),
      "item_revision": 8,
      "items_change_seq": 43
    },
    "shifted": [{"item_id":"shifted-item","item_revision":9}]
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

let sampleTaskBoardPlanningResponseText =
  """
  {
    "transition": {
      "board_item_id": "board-1",
      "from_status": "planning",
      "to_status": "agentic_review",
      "planning": {
        "summary": "Use the semantic plan.",
        "approved_by": null,
        "approved_at": null
      }
    },
    "item": \(sampleTaskBoardItemJSONString)
  }
  """

let sampleOrchestratorSettingsText =
  """
  {
    "enabled_workflows": ["default_task", "pr_fix", "pr_review", "review"],
    "dry_run_default": false,
    "dispatch_status_filter": "todo",
    "project_dir": "/tmp/harness",
    "github_project": {
      "owner": "example",
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
        { "pattern": "apps/harness-monitor" }
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
    "github_inbox": {
      "repositories": ["example/harness", "example/aff"]
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
        "provider": "github",
        "configured": true,
        "linked": 1,
        "pushable": 0,
        "blocked": 0,
        "token_env": ["HARNESS_GITHUB_TOKEN", "GH_TOKEN"]
      }
    ],
    "operations": [
      {
        "provider": "github",
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

let sampleTaskBoardGitRuntimeConfigText =
  """
  {
    "global": {
      "author_name": "Harness Bot",
      "author_email": "bot@example.com",
      "ssh_key_path": "/Users/test/.ssh/id_ed25519",
      "signing": {
        "mode": "ssh",
        "ssh_key_path": "/Users/test/.ssh/id_signing",
        "gpg_key_id": null
      }
    },
    "repository_overrides": [
      {
        "repository": "example/harness",
        "profile": {
          "author_name": "Repo Bot",
          "author_email": "repo@example.com",
          "ssh_key_path": "/Users/test/.ssh/id_repo",
          "signing": {
            "mode": "gpg",
            "ssh_key_path": null,
            "gpg_key_id": "ABC123"
          }
        }
      }
    ]
  }
  """

let sampleGitHubTokensSyncText =
  """
  {
    "global_token_configured": true,
    "repository_token_count": 1
  }
  """

let sampleTodoistTokenSyncText =
  """
  {
    "token_configured": true
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
