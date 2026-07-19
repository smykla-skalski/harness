use std::collections::BTreeMap;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use crate::task_board::github::{
    GitHubBranchProtectionEvidence, GitHubCheckEvidence, GitHubMergeEvidence, GitHubProjectConfig,
    GitHubPullRequestEvidence, GitHubPullRequestHandle, GitHubReviewEvidence,
};
use crate::task_board::{TaskBoardItem, TaskBoardOrchestratorDispatchInput, TaskBoardStatus};
use tempfile::tempdir;

use super::support::{STEP_MERGED, STEP_WAITING_FOR_REVIEW, managed_branch_name};
use super::{AutomationRequest, automate_item};

const TEST_HOST_ID: &str = "host1234";

#[path = "tests/fake_client.rs"]
mod fake_client;
use fake_client::FakeGitHubClient;
#[path = "tests/write_publication.rs"]
mod write_publication;

#[tokio::test]
async fn automation_opens_reviews_and_merges_prs() {
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
    std::fs::write(repo.join("feature.txt"), b"feature\n").expect("write feature");
    run_git(&repo, &["add", "feature.txt"]);
    run_git(
        &repo,
        &["-c", "commit.gpgsign=false", "commit", "-m", "feature"],
    );

    let mut config = GitHubProjectConfig::new("owner", "repo", repo.clone());
    config
        .enabled_automations
        .enabled
        .push(crate::task_board::github::GitHubAutomation::AutoMerge);
    config.requested_reviewers.reviewers = vec!["alice".to_string(), "bob".to_string()];
    let input = TaskBoardOrchestratorDispatchInput {
        item_id: None,
        status: Some(TaskBoardStatus::Done),
        dry_run: false,
        project_dir: Some(repo.to_string_lossy().into_owned()),
        actor: None,
    };
    let mut item = TaskBoardItem::new(
        "task-1".to_string(),
        "Task".to_string(),
        String::new(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Done;
    item.project_id = Some("owner/repo".to_string());
    item.workflow.worktree = Some(repo.to_string_lossy().into_owned());
    let expected_branch = managed_branch_name(&config, &item.id, TEST_HOST_ID);
    let client = FakeGitHubClient {
        pull_request: GitHubPullRequestHandle {
            number: 42,
            html_url: Some("https://example.test/pull/42".to_string()),
            draft: true,
            open: true,
            merged: false,
            head_sha: "abc123".to_string(),
            head_repository: Some("owner/repo".into()),
            head_branch: Some(expected_branch.clone()),
            requested_reviewers: Vec::new(),
            requested_team_reviewers: Vec::new(),
        },
        evidence: GitHubMergeEvidence {
            pull_request: GitHubPullRequestEvidence {
                number: 42,
                html_url: Some("https://example.test/pull/42".to_string()),
                base_branch: "main".to_string(),
                head_branch: expected_branch.clone(),
                draft: false,
                changed_paths: vec!["feature.txt".to_string()],
            },
            checks: vec![GitHubCheckEvidence::success("ci")],
            reviews: vec![GitHubReviewEvidence::approved("reviewer")],
            branch_protection: GitHubBranchProtectionEvidence {
                enabled: true,
                merge_allowed: true,
                required_checks: vec!["ci".to_string()],
            },
        },
        create_calls: std::sync::Mutex::new(0),
        publish_calls: std::sync::Mutex::new(0),
        ready_calls: std::sync::Mutex::new(0),
        reviewer_requests: std::sync::Mutex::new(Vec::new()),
        merge_calls: std::sync::Mutex::new(0),
        ready_error: std::sync::Mutex::new(None),
        parent_interleaving: std::sync::Mutex::new(None),
    };

    let workflow = automate_item(AutomationRequest {
        board_root: temp.path(),
        config: &config,
        project_dir: input.project_dir.as_deref(),
        dry_run: false,
        item: &item,
        session_worktrees: &BTreeMap::new(),
        client: &client,
        host_id: TEST_HOST_ID,
    })
    .await;

    assert_eq!(workflow.branch.as_deref(), Some(expected_branch.as_str()));
    assert_eq!(workflow.pr_number, Some(42));
    assert_eq!(workflow.current_step_id.as_deref(), Some(STEP_MERGED));
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 1);
    assert_eq!(*client.create_calls.lock().expect("create calls"), 1);
    assert_eq!(*client.ready_calls.lock().expect("ready calls"), 1);
    assert_eq!(
        client
            .reviewer_requests
            .lock()
            .expect("reviewer requests")
            .as_slice(),
        &[(vec!["alice".to_string(), "bob".to_string()], Vec::new())]
    );
    assert_eq!(*client.merge_calls.lock().expect("merge calls"), 1);
    assert_eq!(
        git_ref(&remote, &format!("refs/heads/{expected_branch}")),
        git_ref(&repo, "HEAD")
    );
}

#[tokio::test]
async fn automation_waits_for_review_when_merge_evidence_is_not_approved() {
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
    let mut config = GitHubProjectConfig::new("owner", "repo", repo.clone());
    config
        .enabled_automations
        .enabled
        .push(crate::task_board::github::GitHubAutomation::AutoMerge);
    let mut item = TaskBoardItem::new(
        "task-2".to_string(),
        "Task".to_string(),
        String::new(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    let expected_branch = managed_branch_name(&config, &item.id, TEST_HOST_ID);
    run_git(
        &repo,
        &["push", "origin", &format!("HEAD:{expected_branch}")],
    );
    item.status = TaskBoardStatus::Done;
    item.project_id = Some("owner/repo".to_string());
    item.workflow.worktree = Some(repo.to_string_lossy().into_owned());
    item.workflow.branch = Some(expected_branch.clone());
    item.workflow.pr_number = Some(7);
    let client = FakeGitHubClient {
        pull_request: GitHubPullRequestHandle {
            number: 7,
            html_url: Some("https://example.test/pull/7".to_string()),
            draft: false,
            open: true,
            merged: false,
            head_sha: "abc123".to_string(),
            head_repository: Some("owner/repo".into()),
            head_branch: Some(expected_branch.clone()),
            requested_reviewers: Vec::new(),
            requested_team_reviewers: Vec::new(),
        },
        evidence: GitHubMergeEvidence {
            pull_request: GitHubPullRequestEvidence {
                number: 7,
                html_url: None,
                base_branch: "main".to_string(),
                head_branch: expected_branch.clone(),
                draft: false,
                changed_paths: vec!["feature.txt".to_string()],
            },
            checks: vec![GitHubCheckEvidence::success("ci")],
            reviews: Vec::new(),
            branch_protection: GitHubBranchProtectionEvidence {
                enabled: true,
                merge_allowed: true,
                required_checks: vec!["ci".to_string()],
            },
        },
        create_calls: std::sync::Mutex::new(0),
        publish_calls: std::sync::Mutex::new(0),
        ready_calls: std::sync::Mutex::new(0),
        reviewer_requests: std::sync::Mutex::new(Vec::new()),
        merge_calls: std::sync::Mutex::new(0),
        ready_error: std::sync::Mutex::new(None),
        parent_interleaving: std::sync::Mutex::new(None),
    };

    let workflow = automate_item(AutomationRequest {
        board_root: temp.path(),
        config: &config,
        project_dir: None,
        dry_run: false,
        item: &item,
        session_worktrees: &BTreeMap::new(),
        client: &client,
        host_id: TEST_HOST_ID,
    })
    .await;

    assert_eq!(
        workflow.current_step_id.as_deref(),
        Some(STEP_WAITING_FOR_REVIEW)
    );
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 0);
    assert!(
        client
            .reviewer_requests
            .lock()
            .expect("reviewer requests")
            .is_empty()
    );
    assert_eq!(*client.merge_calls.lock().expect("merge calls"), 0);
}

#[tokio::test]
async fn automation_waits_for_commits_before_opening_a_pull_request() {
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

    let config = GitHubProjectConfig::new("owner", "repo", repo.clone());
    let mut item = TaskBoardItem::new(
        "task-3".to_string(),
        "Task".to_string(),
        String::new(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Done;
    item.project_id = Some("owner/repo".to_string());
    item.workflow.worktree = Some(repo.to_string_lossy().into_owned());
    let expected_branch = managed_branch_name(&config, &item.id, TEST_HOST_ID);
    let client = FakeGitHubClient {
        pull_request: GitHubPullRequestHandle {
            number: 99,
            html_url: Some("https://example.test/pull/99".to_string()),
            draft: true,
            open: true,
            merged: false,
            head_sha: "abc123".to_string(),
            head_repository: Some("owner/repo".into()),
            head_branch: Some(expected_branch.clone()),
            requested_reviewers: Vec::new(),
            requested_team_reviewers: Vec::new(),
        },
        evidence: GitHubMergeEvidence {
            pull_request: GitHubPullRequestEvidence {
                number: 99,
                html_url: Some("https://example.test/pull/99".to_string()),
                base_branch: "main".to_string(),
                head_branch: expected_branch.clone(),
                draft: true,
                changed_paths: vec![],
            },
            checks: vec![],
            reviews: vec![],
            branch_protection: GitHubBranchProtectionEvidence {
                enabled: true,
                merge_allowed: true,
                required_checks: vec![],
            },
        },
        create_calls: std::sync::Mutex::new(0),
        publish_calls: std::sync::Mutex::new(0),
        ready_calls: std::sync::Mutex::new(0),
        reviewer_requests: std::sync::Mutex::new(Vec::new()),
        merge_calls: std::sync::Mutex::new(0),
        ready_error: std::sync::Mutex::new(None),
        parent_interleaving: std::sync::Mutex::new(None),
    };

    let workflow = automate_item(AutomationRequest {
        board_root: temp.path(),
        config: &config,
        project_dir: Some(repo.to_string_lossy().as_ref()),
        dry_run: false,
        item: &item,
        session_worktrees: &BTreeMap::new(),
        client: &client,
        host_id: TEST_HOST_ID,
    })
    .await;

    assert_eq!(
        workflow.current_step_id.as_deref(),
        Some("github_waiting_for_commits")
    );
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 0);
    assert_eq!(*client.create_calls.lock().expect("create calls"), 0);
}

#[test]
fn managed_branch_name_includes_host_prefix() {
    let config = GitHubProjectConfig::new("owner", "repo", PathBuf::new());
    let branch = managed_branch_name(&config, "dup-1", "abcdef12");
    assert_eq!(branch, "c/dup-1-abcdef12");
}

#[test]
fn managed_branch_name_truncates_long_host_id() {
    let config = GitHubProjectConfig::new("owner", "repo", PathBuf::new());
    let long_host = "abcdef0123456789-extra";
    let branch = managed_branch_name(&config, "dup-1", long_host);
    assert_eq!(branch, "c/dup-1-abcdef01");
}

fn init_repo(path: &Path) {
    std::fs::create_dir_all(path).expect("create repo");
    run_git(path, &["init", "-b", "main"]);
    run_git(path, &["config", "user.email", "test@example.com"]);
    run_git(path, &["config", "user.name", "test"]);
    std::fs::write(path.join("README.md"), b"seed\n").expect("write seed");
    run_git(path, &["add", "README.md"]);
    run_git(
        path,
        &["-c", "commit.gpgsign=false", "commit", "-m", "seed"],
    );
}

fn run_git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(["-C"])
        .arg(dir)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
}

fn git_ref(dir: &Path, reference: &str) -> String {
    let mut command = Command::new("git");
    if dir.join("HEAD").is_file() && dir.join("objects").is_dir() && !dir.join(".git").exists() {
        command.args(["--git-dir"]).arg(dir);
    } else {
        command.args(["-C"]).arg(dir);
    }
    let output = command
        .args(["rev-parse", reference])
        .output()
        .expect("git rev-parse");
    assert!(
        output.status.success(),
        "git rev-parse failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn git_tree(dir: &Path, reference: &str) -> String {
    git_ref(dir, &format!("{reference}^{{tree}}"))
}

fn git_ref_exists(dir: &Path, reference: &str) -> bool {
    let mut command = Command::new("git");
    if dir.join("HEAD").is_file() && dir.join("objects").is_dir() && !dir.join(".git").exists() {
        command.args(["--git-dir"]).arg(dir);
    } else {
        command.args(["-C"]).arg(dir);
    }
    command
        .args(["rev-parse", "--verify", "--quiet", reference])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn remote_repo_path(repo: &Path) -> PathBuf {
    PathBuf::from(git_stdout(repo, &["config", "--get", "remote.origin.url"]))
}

fn git_stdout(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-C"])
        .arg(dir)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}
