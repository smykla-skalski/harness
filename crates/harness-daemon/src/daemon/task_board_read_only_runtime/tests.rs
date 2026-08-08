use chrono::{TimeZone, Utc};
use tempfile::tempdir;

use super::*;
use crate::reviews::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionResult, ReviewCheckStatus, ReviewItem,
    ReviewItemFlags, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
    ReviewsActionResponse,
};

#[test]
fn local_head_resolves_full_commit_oid() {
    let temp = tempdir().expect("tempdir");
    harness_testkit::init_git_repo_with_seed(temp.path());

    let head = git_evidence::local_head(temp.path()).expect("resolve local head");

    assert_eq!(head.len(), 40);
    assert!(head.bytes().all(|byte| byte.is_ascii_hexdigit()));
}

#[test]
fn publish_mapping_requires_one_applied_approval() {
    let review = review_item();
    let applied = ReviewsActionResponse {
        summary: "approved".into(),
        results: vec![action_result(ReviewActionOutcome::Applied, None)],
    };
    require_applied_approval(&applied, &review).expect("applied approval");

    let skipped = ReviewsActionResponse {
        summary: "skipped".into(),
        results: vec![action_result(
            ReviewActionOutcome::Skipped,
            Some("policy declined"),
        )],
    };
    let error = require_applied_approval(&skipped, &review).expect_err("skipped approval");
    assert!(error.message().contains("policy declined"));
}

#[test]
fn production_adapter_satisfies_runtime_contract() {
    fn assert_runtime<T: TaskBoardReadOnlyRuntime>() {}
    assert_runtime::<ProductionTaskBoardReadOnlyRuntime<'static>>();
    let constructor = ProductionTaskBoardReadOnlyRuntime::new;
    let load = ProductionTaskBoardReadOnlyRuntime::load_codex_report_run;
    let start = ProductionTaskBoardReadOnlyRuntime::start_report_run;
    let resolve = ProductionTaskBoardReadOnlyRuntime::resolve_exact_head;
    let publish = ProductionTaskBoardReadOnlyRuntime::publish_pr_review;
    let verify = ProductionTaskBoardReadOnlyRuntime::verify_pr_review_approval;
    let _ = (constructor, load, start, resolve, publish, verify);
}

fn action_result(outcome: ReviewActionOutcome, message: Option<&str>) -> ReviewActionResult {
    ReviewActionResult {
        repository: "example/compass".into(),
        number: 17,
        action: ReviewActionKind::Approve,
        outcome,
        message: message.map(str::to_owned),
        timeline_entry: None,
    }
}

fn review_item() -> ReviewItem {
    let timestamp = Utc
        .with_ymd_and_hms(2026, 7, 17, 10, 0, 0)
        .single()
        .expect("timestamp");
    ReviewItem {
        pull_request_id: "pr-node-17".into(),
        repository_id: "repo-node".into(),
        repository: "example/compass".into(),
        number: 17,
        title: "Review me".into(),
        url: "https://github.com/example/compass/pull/17".into(),
        base_ref_name: Some("main".into()),
        default_branch_name: Some("main".into()),
        backport_source: None,
        author_login: "author".into(),
        author_avatar_url: None,
        author_association: crate::reviews::ReviewAuthorAssociation::default(),
        state: ReviewPullRequestState::Open,
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: ReviewCheckStatus::Success,
        flags: ReviewItemFlags::default(),
        viewer_can_merge_as_admin: true,
        head_sha: "head-amber".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 3,
        deletions: 1,
        created_at: timestamp,
        updated_at: timestamp,
        required_failed_check_names: Vec::new(),
        required_approving_review_count: None,
        has_conflict_markers: None,
        viewer_has_active_approval: Some(false),
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}
