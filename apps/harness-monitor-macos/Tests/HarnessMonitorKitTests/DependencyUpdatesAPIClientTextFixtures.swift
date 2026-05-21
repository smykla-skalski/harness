let sampleDependencyUpdateItemJSONString =
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
        "check_suite_id": "suite-1"
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

let sampleDependencyUpdatesQueryResponseText =
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
      \(sampleDependencyUpdateItemJSONString)
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

let sampleDependencyUpdatesMergeResponseText =
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

let sampleDependencyUpdatesRerunResponseText =
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

let sampleDependencyUpdatesLabelResponseText =
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

let sampleDependencyUpdatesAutoResponseText =
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

let sampleDepsCacheClearResponseText =
  """
  {
    "cleared_entries": 2
  }
  """

let sampleDependencyUpdatesRefreshResponseText =
  """
  {
    "fetched_at": "2026-05-21T12:00:00Z",
    "items": [],
    "missing_pull_request_ids": ["pr-42"]
  }
  """
