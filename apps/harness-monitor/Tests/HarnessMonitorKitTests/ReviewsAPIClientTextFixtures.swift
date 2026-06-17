let sampleReviewItemJSONString =
  """
  {
    "pull_request_id": "pr-42",
    "repository_id": "repo-1",
    "repository": "example/harness",
    "number": 42,
    "title": "chore(deps): bump swift-nio",
    "url": "https://github.com/example/harness/pull/42",
    "author_login": "renovate[bot]",
    "state": "open",
    "mergeable": "mergeable",
    "review_status": "review_required",
    "check_status": "success",
    "policy_blocked": false,
    "is_draft": false,
    "head_sha": "abc123",
    "labels": ["dependencies"],
    "checks": [
      {
        "name": "ci",
        "status": "completed",
        "conclusion": "success",
        "check_suite_id": "suite-1",
        "details_url": "https://github.com/example/harness/actions/runs/1001/job/2002"
      },
      {
        "name": "legacy/ci",
        "status": "completed",
        "conclusion": "success",
        "details_url": "https://ci.example.com/example/harness/builds/42"
      }
    ],
    "reviews": [
      {
        "author": "review-bot",
        "state": "commented"
      }
    ],
    "additions": 12,
    "deletions": 4,
    "created_at": "2026-05-20T12:00:00Z",
    "updated_at": "2026-05-20T12:30:00Z"
  }
  """

let sampleReviewsQueryResponseText =
  """
  {
    "fetched_at": "2026-05-20T12:45:00Z",
    "from_cache": false,
    "summary": {
      "total": 1,
      "review_required": 1,
      "ready_to_merge": 0,
      "auto_approvable": 1,
      "waiting_on_checks": 0,
      "blocked": 0
    },
    "items": [
      \(sampleReviewItemJSONString)
    ]
  }
  """

let sampleDepsCatalogResponseText =
  """
  {
    "organization": "example",
    "repositories": [
      "example/aff",
      "example/harness"
    ]
  }
  """

let sampleReviewsCapabilitiesResponseText =
  """
  {
    "schema_version": 1,
    "supports_action_preview": true,
    "supports_check_run_links": true,
    "supports_repository_sync_health": true,
    "supports_persistent_action_diagnostics": true
  }
  """

let sampleActionPreviewText =
  """
  {
    "action": "merge",
    "capabilities": {
      "schema_version": 1,
      "supports_action_preview": true,
      "supports_check_run_links": true,
      "supports_repository_sync_health": true,
      "supports_persistent_action_diagnostics": true
    },
    "total_count": 1,
    "actionable_count": 1,
    "skipped_count": 0,
    "warnings": [],
    "targets": [
      {
        "pull_request_id": "pr-42",
        "repository": "example/harness",
        "number": 42,
        "eligible": true,
        "warnings": []
      }
    ]
  }
  """

let sampleDepsApproveResponseText =
  """
  {
    "summary": "Approved 1 dependency update.",
    "results": [
      {
        "repository": "example/harness",
        "number": 42,
        "action": "approve",
        "outcome": "applied",
        "message": null
      }
    ]
  }
  """

let sampleReviewsMergeResponseText =
  """
  {
    "summary": "Merged 1 dependency update.",
    "results": [
      {
        "repository": "example/harness",
        "number": 42,
        "action": "merge",
        "outcome": "applied",
        "message": null
      }
    ]
  }
  """

let sampleReviewsRerunResponseText =
  """
  {
    "summary": "Reran checks for 1 dependency update.",
    "results": [
      {
        "repository": "example/harness",
        "number": 42,
        "action": "rerun_checks",
        "outcome": "applied",
        "message": null
      }
    ]
  }
  """

let sampleReviewsLabelResponseText =
  """
  {
    "summary": "Added labels to 1 dependency update.",
    "results": [
      {
        "repository": "example/harness",
        "number": 42,
        "action": "add_label",
        "outcome": "applied",
        "message": null
      }
    ]
  }
  """

let sampleReviewsAutoResponseText =
  """
  {
    "summary": "Auto mode finished for 1 dependency update.",
    "results": [
      {
        "repository": "example/harness",
        "number": 42,
        "action": "auto_merge",
        "outcome": "applied",
        "message": null
      }
    ]
  }
  """

let sampleReviewsPolicyPreviewResponseText =
  """
  {
    "eligible": true,
    "reason": null,
    "steps": [
      {
        "step_type": "action",
        "action_key": "reviews.approve"
      },
      {
        "step_type": "wait",
        "waiting_on": {
          "event_key": "reviews.checks_passed"
        }
      },
      {
        "step_type": "action",
        "action_key": "reviews.merge"
      }
    ],
    "warnings": [
      "Merge will wait for required checks to pass."
    ]
  }
  """

let sampleReviewsPolicyRunResponseText =
  """
  {
    "run_id": "run-42",
    "workflow_id": "reviews_auto",
    "subject": {
      "repository": "example/harness",
      "pull_request_number": 42
    },
    "trigger": "manual",
    "status": "waiting",
    "started_at": "2026-05-29T12:00:00Z",
    "updated_at": "2026-05-29T12:00:01Z",
    "waiting_on": {
      "event_key": "reviews.checks_passed"
    },
    "completed_at": null,
    "error_message": null,
    "steps": [
      {
        "step_type": "action",
        "action_key": "reviews.approve",
        "recorded_at": "2026-05-29T12:00:00Z"
      },
      {
        "step_type": "wait",
        "waiting_on": {
          "event_key": "reviews.checks_passed"
        },
        "recorded_at": "2026-05-29T12:00:01Z"
      }
    ]
  }
  """

let sampleReviewsPolicyStatusResponseText =
  """
  {
    "active_run": {
      "run_id": "run-42",
      "workflow_id": "reviews_auto",
      "subject": {
        "repository": "example/harness",
        "pull_request_number": 42
      },
      "trigger": "manual",
      "status": "waiting",
      "started_at": "2026-05-29T12:00:00Z",
      "updated_at": "2026-05-29T12:00:01Z",
      "waiting_on": {
        "event_key": "reviews.checks_passed"
      },
      "completed_at": null,
      "error_message": null,
      "steps": [
        {
          "step_type": "action",
          "action_key": "reviews.approve",
          "recorded_at": "2026-05-29T12:00:00Z"
        },
        {
          "step_type": "wait",
          "waiting_on": {
            "event_key": "reviews.checks_passed"
          },
          "recorded_at": "2026-05-29T12:00:01Z"
        }
      ]
    },
    "recent_runs": [
      {
        "run_id": "run-42",
        "workflow_id": "reviews_auto",
        "subject": {
          "repository": "example/harness",
          "pull_request_number": 42
        },
        "trigger": "manual",
        "status": "waiting",
        "started_at": "2026-05-29T12:00:00Z",
        "updated_at": "2026-05-29T12:00:01Z",
        "waiting_on": {
          "event_key": "reviews.checks_passed"
        },
        "completed_at": null,
        "error_message": null,
        "steps": [
          {
            "step_type": "action",
            "action_key": "reviews.approve",
            "recorded_at": "2026-05-29T12:00:00Z"
          },
          {
            "step_type": "wait",
            "waiting_on": {
              "event_key": "reviews.checks_passed"
            },
            "recorded_at": "2026-05-29T12:00:01Z"
          }
        ]
      }
    ]
  }
  """

let sampleDepsCacheClearResponseText =
  """
  {
    "cleared_entries": 2
  }
  """

let sampleReviewsRefreshResponseText =
  """
  {
    "fetched_at": "2026-05-21T12:00:00Z",
    "items": [],
    "missing_pull_request_ids": ["pr-42"]
  }
  """

let sampleReviewsCommentResponseText =
  """
  {
    "summary": "Posted dependency update comment.",
    "results": [
      {
        "repository": "example/harness",
        "number": 42,
        "action": "comment",
        "outcome": "applied",
        "message": null,
        "timeline_entry": {
          "kind": "issue_comment",
          "id": "IC_comment_001",
          "created_at": "2026-05-22T11:00:00Z",
          "body": "@renovatebot rebase",
          "is_minimized": false,
          "reactions_total": 0,
          "viewer_did_author": true,
          "viewer_can_edit": true
        }
      }
    ]
  }
  """

let sampleReviewsTimelineResponseText =
  """
  {
    "pull_request_id": "pr-42",
    "entries": [
      {
        "kind": "issue_comment",
        "id": "IC_001",
        "created_at": "2026-05-22T10:00:00Z",
        "body": "ship it",
        "is_minimized": false,
        "reactions_total": 0,
        "viewer_did_author": false,
        "viewer_can_edit": false,
        "author": { "login": "alice", "avatarUrl": null }
      }
    ],
    "page_info": {
      "start_cursor": "start",
      "end_cursor": "end",
      "has_older": true,
      "has_newer": false
    },
    "viewer_can_comment": true,
    "fetched_at": "2026-05-22T15:00:00Z"
  }
  """

let sampleReviewsAvatarResponseText =
  """
  {
    "avatar_url": "https://avatars.githubusercontent.com/in/2740?v=4",
    "mime_type": "image/png",
    "content_base64": "iVBORw0KGgo=",
    "fetched_at": "2026-05-22T10:00:00Z"
  }
  """

let sampleReviewsBodyUpdateResponseText =
  """
  {
    "pull_request_id": "PR_kwReview1",
    "outcome": "updated",
    "current_body": "Updated description body.",
    "current_body_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    "pr_updated_at": "2026-05-22T10:05:00Z",
    "fetched_at": "2026-05-22T10:05:01Z"
  }
  """

let sampleReviewsFileCommentResponseText =
  """
  {
    "pull_request_id": "PR_kwReview1",
    "thread_id": "PRRT_thread1",
    "comment_id": "PRRC_comment1",
    "url": "https://github.com/example/harness/pull/1#discussion_r1",
    "fetched_at": "2026-05-22T10:06:00Z"
  }
  """

let sampleReviewsReviewThreadResolveResponseText =
  """
  {
    "thread_id": "PRRT_thread1",
    "resolved": true
  }
  """

let sampleReviewsFilesListResponseText =
  """
  {
    "pull_request_id": "PR_kwReview1",
    "number": 42,
    "head_ref_oid": "abc123",
    "head_ref_name": "feature/x",
    "base_ref_oid": "def456",
    "base_ref_name": "main",
    "repository_full_name": "example/harness",
    "viewer_can_mark_viewed": true,
    "files": [
      {
        "path": "src/main.rs",
        "previous_path": null,
        "change_type": "modified",
        "additions": 10,
        "deletions": 2,
        "viewer_viewed_state": "viewed",
        "is_binary": false,
        "language_hint": "rust",
        "mode_change": null
      }
    ],
    "fetched_at": "2026-05-22T10:00:00Z",
    "pagination_complete": true,
    "rate_limit_snapshot": {
      "remaining": 4900,
      "limit": 5000,
      "reset_at": "2026-05-22T11:00:00Z",
      "cost": 1
    }
  }
  """
