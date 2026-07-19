use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::json;
use tempfile::{TempDir, tempdir};

use crate::task_board::github::{
    GitHubAutomation, GitHubBranchProtectionEvidence, GitHubCheckEvidence, GitHubMergeEvidence,
    GitHubProjectConfig, GitHubPullRequestEvidence, GitHubPullRequestHandle,
};
use crate::task_board::{
    PolicyGraph, TaskBoardItem, TaskBoardPullRequestHeadIdentity, TaskBoardStatus,
};

use super::super::write_publication::{
    PrFixBranchRequest, default_publication_result, prepare_default_publication_item,
    publish_pr_fix_branch,
};
use super::super::{DatabaseAutomationRequest, automate_item_with_database_policy};
use super::{FakeGitHubClient, git_ref, git_tree, init_repo, managed_branch_name, run_git};

const HOST_ID: &str = "task-board-write-workflow";

#[tokio::test]
async fn pr_fix_policy_deny_prevents_real_git_push() {
    let fixture = PublicationFixture::new();
    let client = fixture.client(false);
    let item = fixture.item("portfolio-project", fixture.repo.as_path());
    let policy = deny_push_policy();
    let error = publish_pr_fix_branch(PrFixBranchRequest {
        client: &client,
        config: &fixture.config,
        worktree: &fixture.repo,
        head: &fixture.head,
        item: &item,
        policy: Some(("deny-push", &policy)),
        pull_request: 42,
        reviewed_tree: &fixture.reviewed_tree,
    })
    .await
    .expect_err("policy must deny PrFix publication");

    assert!(error.to_string().contains("policy blocked PushBranch"));
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 0);
    assert_eq!(
        git_ref(&fixture.remote, "refs/heads/feature/fix"),
        fixture.base
    );
}

#[tokio::test]
async fn pr_fix_requires_create_branch_immediately_before_push() {
    let mut fixture = PublicationFixture::new();
    fixture.config.enabled_automations.enabled = vec![GitHubAutomation::OpenPullRequest];
    let client = fixture.client(false);
    let item = fixture.item("portfolio-project", fixture.repo.as_path());

    let error = publish_pr_fix_branch(PrFixBranchRequest {
        client: &client,
        config: &fixture.config,
        worktree: &fixture.repo,
        head: &fixture.head,
        item: &item,
        policy: None,
        pull_request: 42,
        reviewed_tree: &fixture.reviewed_tree,
    })
    .await
    .expect_err("disabled CreateBranch must block mutation");

    assert!(error.to_string().contains("CreateBranch"));
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 0);
}

#[tokio::test]
async fn parent_interleaving_with_the_same_tree_is_rejected() {
    let fixture = PublicationFixture::new();
    let interloper = fixture.same_tree_interloper();
    let client = fixture.client(false);
    *client
        .parent_interleaving
        .lock()
        .expect("parent interleaving") = Some(interloper);
    let item = fixture.item("portfolio-project", fixture.repo.as_path());

    let error = publish_pr_fix_branch(PrFixBranchRequest {
        client: &client,
        config: &fixture.config,
        worktree: &fixture.repo,
        head: &fixture.head,
        item: &item,
        policy: None,
        pull_request: 42,
        reviewed_tree: &fixture.reviewed_tree,
    })
    .await
    .expect_err("interleaved parent must fail compare-and-publish");

    assert!(error.to_string().contains("publication parent changed"));
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 0);
}

#[tokio::test]
async fn default_publication_rejects_same_tree_parent_drift_before_noop() {
    let fixture = PublicationFixture::new();
    let stored = fixture.item("portfolio-project", fixture.repo.as_path());
    let prepared = prepare_default_publication_item(stored, "owner/repo", &fixture.repo)
        .expect("canonical publication item");
    let branch = managed_branch_name(&fixture.config, &prepared.id, HOST_ID);
    let interloper = fixture.interloper_with_tree(&fixture.reviewed_tree);
    run_git(
        &fixture.repo,
        &[
            "push",
            "origin",
            &format!("{interloper}:refs/heads/{branch}"),
        ],
    );
    let client = fixture.client(false);

    let workflow = automate_item_with_database_policy(DatabaseAutomationRequest {
        policy: None,
        config: &fixture.config,
        project_dir: None,
        dry_run: false,
        item: &prepared,
        session_worktrees: &BTreeMap::new(),
        client: &client,
        host_id: HOST_ID,
        expected_parent: Some(&fixture.base),
    })
    .await;

    let error = workflow.last_error.as_deref().expect("parent drift error");
    assert!(error.contains("publication parent changed"), "{error}");
    assert!(error.contains(&fixture.base), "{error}");
    assert!(error.contains(&interloper), "{error}");
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 0);
}

#[tokio::test]
async fn default_publication_uses_canonical_repository_and_frozen_worktree() {
    let fixture = PublicationFixture::new();
    let decoy = fixture.temp.path().join("decoy");
    init_repo(&decoy);
    std::fs::write(decoy.join("unreviewed.txt"), b"unreviewed\n").expect("decoy change");
    run_git(&decoy, &["add", "unreviewed.txt"]);
    run_git(
        &decoy,
        &["-c", "commit.gpgsign=false", "commit", "-m", "unreviewed"],
    );
    let stored = fixture.item("portfolio-project", &decoy);
    let prepared = prepare_default_publication_item(stored.clone(), "owner/repo", &fixture.repo)
        .expect("canonical publication item");
    let client = fixture.client(false);
    let branch = managed_branch_name(&fixture.config, &stored.id, HOST_ID);
    let session_worktrees = BTreeMap::from([("session-1".into(), path(&decoy))]);

    let workflow = automate_item_with_database_policy(DatabaseAutomationRequest {
        policy: None,
        config: &fixture.config,
        project_dir: Some(path(&decoy).as_str()),
        dry_run: false,
        item: &prepared,
        session_worktrees: &session_worktrees,
        client: &client,
        host_id: HOST_ID,
        expected_parent: Some(&fixture.base),
    })
    .await;

    assert!(workflow.last_error.is_none(), "{:?}", workflow.last_error);
    assert_eq!(
        git_tree(&fixture.remote, &format!("refs/heads/{branch}")),
        fixture.reviewed_tree
    );
    assert_ne!(git_tree(&decoy, "HEAD"), fixture.reviewed_tree);
    assert_eq!(stored.project_id.as_deref(), Some("portfolio-project"));
    assert_eq!(
        stored.workflow.worktree.as_deref(),
        Some(path(&decoy).as_str())
    );
    assert_eq!(prepared.project_id.as_deref(), Some("owner/repo"));
    assert_eq!(
        prepared.workflow.worktree.as_deref(),
        Some(path(&fixture.repo).as_str())
    );
}

#[tokio::test]
async fn post_create_metadata_failure_keeps_authoritative_identity() {
    let fixture = PublicationFixture::new();
    let client = fixture.client(true);
    *client.ready_error.lock().expect("ready error") = Some("review metadata failed".into());
    let stored = fixture.item("portfolio-project", fixture.repo.as_path());
    let prepared = prepare_default_publication_item(stored, "owner/repo", &fixture.repo)
        .expect("canonical publication item");

    let workflow = automate_item_with_database_policy(DatabaseAutomationRequest {
        policy: None,
        config: &fixture.config,
        project_dir: None,
        dry_run: false,
        item: &prepared,
        session_worktrees: &BTreeMap::new(),
        client: &client,
        host_id: HOST_ID,
        expected_parent: Some(&fixture.base),
    })
    .await;

    assert!(workflow.last_error.is_some());
    assert_eq!(workflow.pr_number, Some(42));
    assert_eq!(
        default_publication_result(&workflow, None, true).expect("retained identity"),
        (42, true)
    );
    assert_eq!(*client.publish_calls.lock().expect("publish calls"), 1);
    assert_eq!(*client.create_calls.lock().expect("create calls"), 1);
}

struct PublicationFixture {
    temp: TempDir,
    repo: PathBuf,
    remote: PathBuf,
    config: GitHubProjectConfig,
    base: String,
    reviewed_tree: String,
    head: TaskBoardPullRequestHeadIdentity,
}

impl PublicationFixture {
    fn new() -> Self {
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
        run_git(&repo, &["push", "origin", "HEAD:feature/fix"]);
        let base = git_ref(&repo, "HEAD");
        std::fs::write(repo.join("reviewed.txt"), b"reviewed\n").expect("reviewed change");
        run_git(&repo, &["add", "reviewed.txt"]);
        run_git(
            &repo,
            &["-c", "commit.gpgsign=false", "commit", "-m", "reviewed"],
        );
        let reviewed_tree = git_tree(&repo, "HEAD");
        let config = GitHubProjectConfig::new("owner", "repo", repo.clone());
        let head = TaskBoardPullRequestHeadIdentity {
            repository: "owner/repo".into(),
            branch: "feature/fix".into(),
            revision: base.clone(),
        };
        Self {
            temp,
            repo,
            remote,
            config,
            base,
            reviewed_tree,
            head,
        }
    }

    fn item(&self, project_id: &str, worktree: &Path) -> TaskBoardItem {
        let mut item = TaskBoardItem::new(
            "write-publication".into(),
            "Write publication".into(),
            String::new(),
            "2026-07-19T10:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InReview;
        item.project_id = Some(project_id.into());
        item.execution_repository = Some("owner/repo".into());
        item.session_id = Some("session-1".into());
        item.workflow.worktree = Some(path(worktree));
        item
    }

    fn client(&self, draft: bool) -> FakeGitHubClient {
        FakeGitHubClient {
            pull_request: GitHubPullRequestHandle {
                number: 42,
                html_url: Some("https://github.com/owner/repo/pull/42".into()),
                draft,
                open: true,
                merged: false,
                head_sha: self.base.clone(),
                head_repository: Some("owner/repo".into()),
                head_branch: Some("feature/fix".into()),
                requested_reviewers: Vec::new(),
                requested_team_reviewers: Vec::new(),
            },
            evidence: GitHubMergeEvidence {
                pull_request: GitHubPullRequestEvidence {
                    number: 42,
                    html_url: Some("https://github.com/owner/repo/pull/42".into()),
                    base_branch: "main".into(),
                    head_branch: "feature/fix".into(),
                    draft,
                    changed_paths: vec!["reviewed.txt".into()],
                },
                checks: vec![GitHubCheckEvidence::success("ci")],
                reviews: Vec::new(),
                branch_protection: GitHubBranchProtectionEvidence {
                    enabled: true,
                    merge_allowed: true,
                    required_checks: vec!["ci".into()],
                },
            },
            create_calls: Mutex::new(0),
            publish_calls: Mutex::new(0),
            ready_calls: Mutex::new(0),
            reviewer_requests: Mutex::new(Vec::new()),
            merge_calls: Mutex::new(0),
            ready_error: Mutex::new(None),
            parent_interleaving: Mutex::new(None),
        }
    }

    fn same_tree_interloper(&self) -> String {
        let tree = git_tree(&self.repo, &self.base);
        self.interloper_with_tree(&tree)
    }

    fn interloper_with_tree(&self, tree: &str) -> String {
        let interloper = super::git_stdout(
            &self.repo,
            &["commit-tree", tree, "-p", &self.base, "-m", "interloper"],
        );
        run_git(
            &self.repo,
            &[
                "push",
                "origin",
                &format!("{interloper}:refs/heads/interloper"),
            ],
        );
        interloper
    }
}

fn deny_push_policy() -> PolicyGraph {
    serde_json::from_value(json!({
        "schema_version": 2,
        "revision": 7,
        "mode": "enforced",
        "nodes": [
            {
                "id": "push-gate",
                "label": "Push branch",
                "kind": { "kind": "action_gate", "actions": ["push_branch"] },
                "input_ports": ["in"],
                "output_ports": ["match", "default"]
            },
            {
                "id": "deny-push",
                "label": "Deny push",
                "kind": {
                    "kind": "finish",
                    "decision": "deny",
                    "reason_code": "human_required"
                },
                "input_ports": ["in"],
                "output_ports": []
            }
        ],
        "edges": [{
            "id": "push-denied",
            "from_node": "push-gate",
            "from_port": "match",
            "to_node": "deny-push",
            "to_port": "in",
            "condition": { "condition": "action_in", "actions": ["push_branch"] }
        }],
        "groups": [],
        "layout": {}
    }))
    .expect("deny push policy")
}

fn path(value: &Path) -> String {
    value.to_string_lossy().into_owned()
}
