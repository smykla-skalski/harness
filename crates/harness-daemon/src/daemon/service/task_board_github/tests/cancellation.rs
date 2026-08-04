use std::collections::BTreeMap;
use std::sync::Mutex;

use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::task_board::prelude::*;
use crate::task_board::github::{
    GitHubAutomation, GitHubBranchProtectionEvidence, GitHubCheckEvidence, GitHubMergeEvidence,
    GitHubProjectConfig, GitHubPullRequestEvidence, GitHubPullRequestHandle, GitHubReviewEvidence,
};
use crate::task_board::{
    TaskBoardAutomationDesiredMode, TaskBoardAutomationRunTrigger, TaskBoardAutomationScope,
    TaskBoardItem, TaskBoardStatus,
};

use super::super::{DatabaseAutomationRequest, automate_item_with_database_policy};
use super::{FakeGitHubClient, TEST_HOST_ID, init_repo, managed_branch_name, run_git};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::db_open::AsyncDaemonDbConnect;

#[tokio::test]
async fn stop_after_fresh_evidence_prevents_merge() {
    let temp = tempdir().expect("tempdir");
    let repo = temp.path().join("repo");
    let remote = temp.path().join("remote.git");
    init_repo(&repo);
    run_git(
        temp.path(),
        &["init", "--bare", remote.to_string_lossy().as_ref()],
    );
    run_git(
        &repo,
        &["remote", "add", "origin", remote.to_string_lossy().as_ref()],
    );
    run_git(&repo, &["push", "-u", "origin", "HEAD:main"]);

    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    db.start_task_board_automation(
        TaskBoardAutomationDesiredMode::Continuous,
        chrono::Utc::now(),
    )
    .await
    .expect("start automation");
    let start = super::super::super::TaskBoardAutomationRunSession::acquire(
        &db,
        TaskBoardAutomationRunTrigger::Manual,
        Some("operator".into()),
        false,
        TaskBoardAutomationScope::default(),
    )
    .await
    .expect("acquire run");
    let super::super::super::TaskBoardAutomationRunStart::Acquired(session) = start else {
        panic!("manual run should be acquired");
    };

    let mut config = GitHubProjectConfig::new("owner", "repo");
    config
        .enabled_automations
        .enabled
        .push(GitHubAutomation::AutoMerge);
    let mut item = TaskBoardItem::new(
        "cancel-before-merge".into(),
        "Cancel before merge".into(),
        String::new(),
        "2026-08-03T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Done;
    item.project_id = Some("owner/repo".into());
    item.workflow.worktree = Some(repo.to_string_lossy().into_owned());
    let branch = managed_branch_name(&config, &item.id, TEST_HOST_ID);
    run_git(&repo, &["push", "origin", &format!("HEAD:{branch}")]);
    item.workflow.branch = Some(branch.clone());
    item.workflow.pr_number = Some(42);

    let client = FakeGitHubClient {
        checkout: repo,
        pull_request: GitHubPullRequestHandle {
            number: 42,
            html_url: Some("https://example.test/pull/42".into()),
            draft: false,
            open: true,
            merged: false,
            head_sha: "abc123".into(),
            head_repository: Some("owner/repo".into()),
            head_branch: Some(branch.clone()),
            requested_reviewers: Vec::new(),
            requested_team_reviewers: Vec::new(),
        },
        evidence: merge_evidence(branch),
        create_calls: Mutex::new(0),
        publish_calls: Mutex::new(0),
        ready_calls: Mutex::new(0),
        reviewer_requests: Mutex::new(Vec::new()),
        merge_calls: Mutex::new(0),
        ready_error: Mutex::new(None),
        parent_interleaving: Mutex::new(None),
        stop_automation_on_fresh_evidence: Some(db),
    };

    let error = automate_item_with_database_policy(DatabaseAutomationRequest {
        policy: None,
        config: &config,
        dry_run: false,
        item: &item,
        session_worktrees: &BTreeMap::new(),
        client: &client,
        host_id: TEST_HOST_ID,
        expected_parent: None,
        session: Some(&session),
    })
    .await
    .expect_err("Stop must fence the merge");

    assert_eq!(error.code(), "KSRCLI092");
    assert_eq!(*client.merge_calls.lock().expect("merge calls"), 0);
}

fn merge_evidence(branch: String) -> GitHubMergeEvidence {
    GitHubMergeEvidence {
        pull_request: GitHubPullRequestEvidence {
            number: 42,
            html_url: Some("https://example.test/pull/42".into()),
            base_branch: "main".into(),
            head_branch: branch,
            draft: false,
            changed_paths: vec!["feature.txt".into()],
        },
        checks: vec![GitHubCheckEvidence::success("ci")],
        reviews: vec![GitHubReviewEvidence::approved("reviewer")],
        branch_protection: GitHubBranchProtectionEvidence {
            enabled: true,
            merge_allowed: true,
            required_checks: vec!["ci".into()],
        },
    }
}
