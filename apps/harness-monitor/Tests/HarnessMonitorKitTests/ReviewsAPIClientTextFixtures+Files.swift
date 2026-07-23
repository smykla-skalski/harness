// Review API client text fixtures, continued. Split from
// ReviewsAPIClientTextFixtures.swift to satisfy the file_length limit.

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
        "updated_at": "2026-05-22T10:01:00Z",
        "actor": { "login": "alice", "avatar_url": "https://avatars.example/alice.png" },
        "body": "ship it",
        "body_text": "ship it",
        "is_minimized": false,
        "reactions_total": 3,
        "viewer_did_author": false,
        "viewer_can_edit": true,
        "url": "https://github.com/example/harness/pull/42#issuecomment-1"
      },
      {
        "kind": "review",
        "id": "RV_002",
        "created_at": "2026-05-22T10:05:00Z",
        "actor": { "login": "bob", "avatar_url": null },
        "state": "changes_requested",
        "body": "needs work",
        "inline_comments": [
          {
            "id": "RC_002a",
            "path": "src/main.rs",
            "line": 12,
            "diff_hunk": "@@ -1 +1 @@",
            "body": "rename this",
            "created_at": "2026-05-22T10:05:01Z",
            "actor": { "login": "bob", "avatar_url": null },
            "outdated": false
          }
        ],
        "comments_truncated": false
      },
      {
        "kind": "review_thread",
        "id": "RT_003",
        "created_at": "2026-05-22T10:10:00Z",
        "actor": { "login": "carol", "avatar_url": null },
        "is_resolved": true,
        "is_collapsed": false,
        "outdated": false,
        "path": "src/lib.rs",
        "line": 7,
        "comments": [
          {
            "id": "RTC_003a",
            "body": "good catch",
            "created_at": "2026-05-22T10:10:01Z",
            "actor": { "login": "carol", "avatar_url": null }
          }
        ],
        "comments_truncated": false
      },
      {
        "kind": "commit",
        "id": "CM_004",
        "created_at": "2026-05-22T10:15:00Z",
        "oid": "deadbeefdeadbeef",
        "abbreviated_oid": "deadbee",
        "message_headline": "fix the thing",
        "committed_date": "2026-05-22T10:14:00Z",
        "author_login": "alice"
      },
      {
        "kind": "head_ref_force_pushed",
        "id": "HF_005",
        "created_at": "2026-05-22T10:20:00Z",
        "actor": { "login": "alice", "avatar_url": null },
        "before_oid": "1111111aaaa",
        "before_abbreviated_oid": "1111111",
        "after_oid": "2222222bbbb",
        "after_abbreviated_oid": "2222222",
        "ref_name": "feature/x"
      },
      {
        "kind": "simple_actor_event",
        "id": "SE_006",
        "created_at": "2026-05-22T10:25:00Z",
        "actor": { "login": "bob", "avatar_url": null },
        "event_kind": "labeled",
        "label": "enhancement",
        "label_color": "84b6eb"
      },
      {
        "kind": "unknown",
        "id": "UK_007",
        "created_at": "2026-05-22T10:30:00Z",
        "typename": "MysteryEvent",
        "raw_payload": {
          "foo": "bar",
          "largeInteger": 9007199254740993
        }
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

let sampleReviewsThreadResolveText =
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

let sampleReviewsFilesPatchResponseText =
  """
  {
    "pull_request_id": "PR_kwReview1",
    "patches": [
      {
        "path": "src/main.rs",
        "patch": "@@ -1 +1 @@\\n-old\\n+new\\n",
        "status": "modified",
        "additions": 1,
        "deletions": 1,
        "truncated": false,
        "etag": "abc-etag",
        "served_by": "local_clone",
        "fetched_at": "2026-05-22T10:00:00Z",
        "head_ref_oid": "abc123"
      }
    ],
    "drifted": false,
    "current_head_ref_oid": "abc123",
    "fetched_at": "2026-05-22T10:00:01Z",
    "rate_limit_snapshot": {
      "remaining": 4800,
      "limit": 5000,
      "reset_at": "2026-05-22T11:00:00Z",
      "cost": 2
    }
  }
  """

let sampleReviewsFilesPreviewResponseText =
  """
  {
    "pull_request_id": "PR_kwReview1",
    "previews": [
      {
        "path": "src/lib.rs",
        "patch": "@@ -1 +1 @@\\n-a\\n+b\\n",
        "status": "modified",
        "additions": 1,
        "deletions": 1,
        "truncated": false,
        "etag": "preview-etag",
        "served_by": "local_clone",
        "fetched_at": "2026-05-22T10:00:00Z",
        "head_ref_oid": "abc123",
        "line_count": 3,
        "line_limit": 1000,
        "has_more": false
      }
    ],
    "drifted": false,
    "current_head_ref_oid": "abc123",
    "fetched_at": "2026-05-22T10:00:01Z",
    "rate_limit_snapshot": {
      "remaining": 4700,
      "limit": 5000,
      "reset_at": "2026-05-22T11:00:00Z",
      "cost": 3
    }
  }
  """

let sampleReviewsFilesViewedResponseText =
  """
  {
    "pull_request_id": "PR_kwReview1",
    "results": [
      {
        "path": "src/main.rs",
        "outcome": "updated",
        "viewer_viewed_state": "viewed"
      }
    ],
    "fetched_at": "2026-05-22T10:00:02Z"
  }
  """

let sampleReviewsFilesBlobResponseText =
  """
  {
    "path": "assets/logo.png",
    "oid": "blob-oid-1",
    "mime": "png",
    "content_base64": "iVBORw0KGgo=",
    "byte_size": 1024,
    "is_truncated": false,
    "is_too_large": false,
    "fetched_at": "2026-05-22T10:00:03Z",
    "rate_limit_snapshot": {
      "remaining": 4600,
      "limit": 5000,
      "reset_at": "2026-05-22T11:00:00Z",
      "cost": 1
    }
  }
  """

let sampleReviewsLocalClonesText =
  """
  [
    {
      "repo_full_name": "kumahq/kuma",
      "repo_key_segment": "kumahq-kuma",
      "size_bytes": 20480,
      "created_at": "2026-05-20T09:00:00Z",
      "last_used_at": "2026-05-22T10:00:00Z",
      "last_fetched_at": "2026-05-22T09:30:00Z"
    }
  ]
  """
