use chrono::{DateTime, Utc};

use crate::reviews::{
    ReviewAuthorAssociation, ReviewCheckStatus, ReviewItem, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewStatus, ReviewsBodyResponse, ReviewsPolicyPreviewResponse,
    ReviewsPolicyPreviewStep, ReviewsPolicyRunResponse, ReviewsPolicyRunStatus,
    ReviewsPolicyRunStep, ReviewsPolicyStepType, ReviewsPolicySubject, ReviewsPolicyTrigger,
    ReviewsPolicyWait,
};

use super::{
    apply_refresh_to_items, auto_policy_results_from_run, cached_body_response, sha256_hex,
    store_cached_body_response,
};

#[path = "reviews_tests/projection.rs"]
mod projection;

fn item(
    pr_id: &str,
    state: ReviewPullRequestState,
    review_status: ReviewReviewStatus,
) -> ReviewItem {
    ReviewItem {
        pull_request_id: pr_id.into(),
        repository_id: "repo_1".into(),
        repository: "acme/api".into(),
        number: 1,
        title: "chore(deps): bump".into(),
        url: "https://example.com".into(),
        base_ref_name: None,
        default_branch_name: None,
        backport_source: None,
        author_login: "renovate[bot]".into(),
        author_avatar_url: None,
        author_association: ReviewAuthorAssociation::None,
        state,
        mergeable: ReviewMergeableState::Mergeable,
        review_status,
        check_status: ReviewCheckStatus::Success,
        flags: crate::reviews::ReviewItemFlags {
            policy_blocked: false,
            is_draft: false,
            viewer_can_update: true,
            viewer_is_requested_reviewer: false,
        },
        viewer_can_merge_as_admin: false,
        head_sha: "abc123".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 1,
        created_at: parsed("2026-05-20T12:00:00Z"),
        updated_at: parsed("2026-05-20T12:00:00Z"),
        required_failed_check_names: Vec::new(),
        required_approving_review_count: None,
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}

fn parsed(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("date")
        .with_timezone(&Utc)
}

#[test]
fn apply_refresh_replaces_matching_open_item() {
    let cached = vec![
        item(
            "pr_1",
            ReviewPullRequestState::Open,
            ReviewReviewStatus::ReviewRequired,
        ),
        item(
            "pr_2",
            ReviewPullRequestState::Open,
            ReviewReviewStatus::ReviewRequired,
        ),
    ];
    let refreshed = vec![item(
        "pr_1",
        ReviewPullRequestState::Open,
        ReviewReviewStatus::Approved,
    )];

    let updated = apply_refresh_to_items(&cached, &refreshed, &[]).expect("changed");
    assert_eq!(updated.len(), 2);
    assert_eq!(updated[0].review_status, ReviewReviewStatus::Approved);
    assert_eq!(updated[1].review_status, ReviewReviewStatus::ReviewRequired);
}

#[test]
fn apply_refresh_drops_closed_or_merged_items() {
    let cached = vec![
        item(
            "pr_1",
            ReviewPullRequestState::Open,
            ReviewReviewStatus::ReviewRequired,
        ),
        item(
            "pr_2",
            ReviewPullRequestState::Open,
            ReviewReviewStatus::ReviewRequired,
        ),
    ];
    let refreshed = vec![item(
        "pr_1",
        ReviewPullRequestState::Merged,
        ReviewReviewStatus::Approved,
    )];

    let updated = apply_refresh_to_items(&cached, &refreshed, &[]).expect("changed");
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].pull_request_id, "pr_2");
}

#[test]
fn apply_refresh_drops_missing_pull_request_ids() {
    let cached = vec![
        item(
            "pr_1",
            ReviewPullRequestState::Open,
            ReviewReviewStatus::ReviewRequired,
        ),
        item(
            "pr_2",
            ReviewPullRequestState::Open,
            ReviewReviewStatus::ReviewRequired,
        ),
    ];
    let updated = apply_refresh_to_items(&cached, &[], &["pr_1".into()]).expect("changed");
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].pull_request_id, "pr_2");
}

#[test]
fn apply_refresh_returns_none_when_no_match() {
    let cached = vec![item(
        "pr_1",
        ReviewPullRequestState::Open,
        ReviewReviewStatus::ReviewRequired,
    )];
    let refreshed = vec![item(
        "pr_other",
        ReviewPullRequestState::Open,
        ReviewReviewStatus::Approved,
    )];
    assert!(apply_refresh_to_items(&cached, &refreshed, &[]).is_none());
    assert!(apply_refresh_to_items(&cached, &[], &["pr_other".into()]).is_none());
}

#[test]
fn apply_refresh_keeps_closed_item_when_refresh_still_reports_open() {
    let cached = vec![item(
        "pr_1",
        ReviewPullRequestState::Open,
        ReviewReviewStatus::ReviewRequired,
    )];
    let refreshed = vec![item(
        "pr_1",
        ReviewPullRequestState::Open,
        ReviewReviewStatus::Approved,
    )];
    let updated = apply_refresh_to_items(&cached, &refreshed, &[]).expect("changed");
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].state, ReviewPullRequestState::Open);
    assert_eq!(updated[0].review_status, ReviewReviewStatus::Approved);
}

fn body_response(pull_request_id: &str, body: &str) -> ReviewsBodyResponse {
    ReviewsBodyResponse {
        pull_request_id: pull_request_id.into(),
        body: body.into(),
        pr_updated_at: parsed("2026-05-20T12:00:00Z"),
        fetched_at: "2026-05-21T00:00:00Z".into(),
        from_cache: false,
    }
}

#[test]
fn cached_body_response_returns_none_for_missing_key() {
    assert!(cached_body_response("body-cache-miss-test-pr", 600).is_none());
}

#[test]
fn cached_body_response_flips_from_cache_on_hit() {
    let key = "body-cache-hit-test-pr".to_string();
    let stored = body_response("pr_body_hit", "Some markdown body.");
    store_cached_body_response(key.clone(), &stored);

    let hit = cached_body_response(&key, 600).expect("cache hit within TTL");
    assert!(
        hit.from_cache,
        "second read should mark response from_cache"
    );
    assert_eq!(hit.pull_request_id, stored.pull_request_id);
    assert_eq!(hit.body, stored.body);
    assert_eq!(hit.pr_updated_at, stored.pr_updated_at);
    assert_eq!(hit.fetched_at, stored.fetched_at);
}

#[test]
fn cached_body_response_distinguishes_cache_keys() {
    let key_a = "body-cache-key-a-pr".to_string();
    let key_b = "body-cache-key-b-pr";
    let stored = body_response("pr_body_a", "Body A");
    store_cached_body_response(key_a.clone(), &stored);

    assert!(cached_body_response(key_b, 600).is_none());
    let hit = cached_body_response(&key_a, 600).expect("hit for stored key");
    assert_eq!(hit.body, "Body A");
}

#[test]
fn store_cached_body_response_overwrites_existing_entry() {
    let key = "body-cache-overwrite-test-pr".to_string();
    store_cached_body_response(key.clone(), &body_response("pr_body_v1", "first"));
    store_cached_body_response(key.clone(), &body_response("pr_body_v2", "second"));

    let hit = cached_body_response(&key, 600).expect("cache hit");
    assert_eq!(hit.pull_request_id, "pr_body_v2");
    assert_eq!(hit.body, "second");
}

#[test]
fn sha256_hex_is_deterministic_lowercase_hex() {
    let digest = sha256_hex("- [ ] rebase\n");
    assert_eq!(digest.len(), 64);
    assert!(digest.bytes().all(|byte| byte.is_ascii_hexdigit()));
    assert!(digest.bytes().all(|byte| !byte.is_ascii_uppercase()));
    assert_eq!(digest, sha256_hex("- [ ] rebase\n"));
}

#[test]
fn sha256_hex_differs_on_single_char_flip() {
    let unchecked = sha256_hex("- [ ] rebase\n");
    let checked = sha256_hex("- [x] rebase\n");
    assert_ne!(unchecked, checked);
}

#[test]
fn sha256_hex_matches_known_empty_string() {
    assert_eq!(
        sha256_hex(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
}

#[test]
fn auto_policy_results_report_waiting_next_step_as_skipped() {
    let target = item(
        "pr_waiting",
        ReviewPullRequestState::Open,
        ReviewReviewStatus::ReviewRequired,
    )
    .target();
    let preview = ReviewsPolicyPreviewResponse {
        workflow_id: "reviews_auto".to_owned(),
        subject: ReviewsPolicySubject {
            repository: target.repository.clone(),
            pull_request_number: target.number,
        },
        eligible: true,
        reason: None,
        warnings: Vec::new(),
        steps: vec![
            ReviewsPolicyPreviewStep {
                step_type: ReviewsPolicyStepType::Action,
                action_key: Some("reviews.approve".to_owned()),
                waiting_on: None,
            },
            ReviewsPolicyPreviewStep {
                step_type: ReviewsPolicyStepType::Wait,
                action_key: None,
                waiting_on: Some(ReviewsPolicyWait {
                    event_key: Some("reviews.checks_passed".to_owned()),
                    duration_seconds: None,
                }),
            },
            ReviewsPolicyPreviewStep {
                step_type: ReviewsPolicyStepType::Action,
                action_key: Some("reviews.merge".to_owned()),
                waiting_on: None,
            },
        ],
    };
    let run = ReviewsPolicyRunResponse {
        workflow_id: "reviews_auto".to_owned(),
        run_id: "run-42".to_owned(),
        subject: ReviewsPolicySubject {
            repository: target.repository.clone(),
            pull_request_number: target.number,
        },
        trigger: ReviewsPolicyTrigger::Manual,
        status: ReviewsPolicyRunStatus::Waiting,
        started_at: "2026-05-29T12:00:00Z".to_owned(),
        updated_at: "2026-05-29T12:00:01Z".to_owned(),
        waiting_on: Some(ReviewsPolicyWait {
            event_key: Some("reviews.checks_passed".to_owned()),
            duration_seconds: None,
        }),
        completed_at: None,
        error_message: None,
        steps: vec![
            ReviewsPolicyRunStep {
                step_type: ReviewsPolicyStepType::Action,
                action_key: Some("reviews.approve".to_owned()),
                waiting_on: None,
                recorded_at: "2026-05-29T12:00:00Z".to_owned(),
            },
            ReviewsPolicyRunStep {
                step_type: ReviewsPolicyStepType::Wait,
                action_key: None,
                waiting_on: Some(ReviewsPolicyWait {
                    event_key: Some("reviews.checks_passed".to_owned()),
                    duration_seconds: None,
                }),
                recorded_at: "2026-05-29T12:00:01Z".to_owned(),
            },
        ],
    };

    let results = auto_policy_results_from_run(&target, &preview, &run);

    assert_eq!(results.len(), 2);
    assert_eq!(
        results[0].outcome,
        crate::reviews::ReviewActionOutcome::Applied
    );
    assert_eq!(
        results[0].action,
        crate::reviews::ReviewActionKind::AutoApprove
    );
    assert_eq!(
        results[1].outcome,
        crate::reviews::ReviewActionOutcome::Skipped
    );
    assert_eq!(
        results[1].action,
        crate::reviews::ReviewActionKind::AutoMerge
    );
    assert_eq!(
        results[1].message.as_deref(),
        Some("waiting for policy event 'reviews.checks_passed' before continuing")
    );
}
