use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::{TempDir, tempdir};

use super::super::types::{BranchPublicationMode, LocalBranchSnapshot, LocalCommitAuthor};
use super::*;
use crate::task_board::TaskBoardGitRuntimeProfile;

#[test]
fn update_rewind_after_preflight_fails_without_overwriting_remote() {
    let fixture = PublicationRaceFixture::new();
    let plan = fixture.plan(
        "feature/update",
        BranchPublicationMode::Update {
            parent_sha: fixture.base.clone(),
        },
    );
    update_ref(
        &fixture.remote,
        "refs/heads/feature/update",
        &fixture.ancestor,
    );

    plan.publish()
        .expect_err("exact update lease must reject a remote rewind");

    assert_eq!(
        git_stdout(&fixture.remote, &["rev-parse", "refs/heads/feature/update"]),
        fixture.ancestor
    );
}

#[test]
fn create_race_after_preflight_fails_without_overwriting_remote() {
    let fixture = PublicationRaceFixture::new();
    let plan = fixture.plan(
        "feature/create",
        BranchPublicationMode::Create {
            parent_sha: fixture.base.clone(),
        },
    );
    update_ref(&fixture.remote, "refs/heads/feature/create", &fixture.base);

    plan.publish()
        .expect_err("empty create lease must reject a newly-created target");

    assert_eq!(
        git_stdout(&fixture.remote, &["rev-parse", "refs/heads/feature/create"]),
        fixture.base
    );
}

#[test]
fn create_allows_default_advance_but_keeps_frozen_parent() {
    let fixture = PublicationRaceFixture::new();
    let plan = fixture.plan(
        "feature/create",
        BranchPublicationMode::Create {
            parent_sha: fixture.base.clone(),
        },
    );
    let advanced = fixture.commit_from(&fixture.base, "default advanced");
    run_git(
        &fixture.worktree,
        &[
            "push",
            fixture.remote_as_str(),
            &format!("{advanced}:refs/heads/main"),
        ],
    );

    plan.publish()
        .expect("an absent target is independent of default advancement");

    assert_eq!(
        git_stdout(
            &fixture.remote,
            &["rev-parse", "refs/heads/feature/create^"]
        ),
        fixture.base
    );
}

#[test]
fn update_with_exact_remote_parent_succeeds() {
    let fixture = PublicationRaceFixture::new();
    let plan = fixture.plan(
        "feature/update",
        BranchPublicationMode::Update {
            parent_sha: fixture.base.clone(),
        },
    );

    plan.publish().expect("exact update lease");

    assert_eq!(
        git_stdout(
            &fixture.remote,
            &["rev-parse", "refs/heads/feature/update^"]
        ),
        fixture.base
    );
}

struct PublicationRaceFixture {
    _temp: TempDir,
    worktree: PathBuf,
    remote: PathBuf,
    ancestor: String,
    base: String,
    snapshot: LocalBranchSnapshot,
}

impl PublicationRaceFixture {
    fn new() -> Self {
        let temp = tempdir().expect("tempdir");
        let worktree = temp.path().join("worktree");
        let remote = temp.path().join("remote.git");
        fs::create_dir_all(&worktree).expect("create worktree");
        run_git(&worktree, &["init", "-b", "main"]);
        run_git(&worktree, &["config", "user.email", "test@example.com"]);
        run_git(&worktree, &["config", "user.name", "Harness Test"]);
        fs::write(worktree.join("README.md"), b"ancestor\n").expect("write ancestor");
        run_git(&worktree, &["add", "README.md"]);
        run_git(
            &worktree,
            &["-c", "commit.gpgsign=false", "commit", "-m", "ancestor"],
        );
        let ancestor = git_stdout(&worktree, &["rev-parse", "HEAD"]);
        fs::write(worktree.join("README.md"), b"base\n").expect("write base");
        run_git(&worktree, &["add", "README.md"]);
        run_git(
            &worktree,
            &["-c", "commit.gpgsign=false", "commit", "-m", "base"],
        );
        let base = git_stdout(&worktree, &["rev-parse", "HEAD"]);
        run_git(temp.path(), &["init", "--bare", path(&remote)]);
        run_git(
            &worktree,
            &[
                "push",
                path(&remote),
                "HEAD:refs/heads/main",
                "HEAD:refs/heads/feature/update",
            ],
        );
        fs::write(worktree.join("reviewed.txt"), b"reviewed\n").expect("write reviewed");
        run_git(&worktree, &["add", "reviewed.txt"]);
        run_git(
            &worktree,
            &[
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "reviewed implementation",
            ],
        );
        let snapshot = LocalBranchSnapshot {
            head_tree_sha: git_stdout(&worktree, &["rev-parse", "HEAD^{tree}"]),
            commit_message: "publish reviewed implementation".into(),
            author: commit_author(),
            committer: commit_author(),
            profile: TaskBoardGitRuntimeProfile::default(),
            existing_signature: None,
        };
        Self {
            _temp: temp,
            worktree,
            remote,
            ancestor,
            base,
            snapshot,
        }
    }

    fn plan(&self, branch: &str, mode: BranchPublicationMode) -> GitPublishPlan {
        let parent_branch = match &mode {
            BranchPublicationMode::Create { .. } => "main",
            BranchPublicationMode::Update { .. } => branch,
        };
        GitPublishPlan {
            worktree: fs::canonicalize(&self.worktree).expect("canonical worktree"),
            remote_url: self.remote.display().to_string(),
            auth_header: github_auth_header("local-token").expect("auth header"),
            fetch_ref: branch_head_ref(parent_branch),
            push_lease: branch_push_lease(branch, &mode),
            push_refspec_prefix: branch_push_refspec_prefix(branch),
            commit_payload: native_commit_payload(&self.snapshot, mode.parent_sha())
                .expect("commit payload"),
        }
    }

    fn commit_from(&self, parent: &str, message: &str) -> String {
        git_stdout(
            &self.worktree,
            &[
                "commit-tree",
                &self.snapshot.head_tree_sha,
                "-p",
                parent,
                "-m",
                message,
            ],
        )
    }

    fn remote_as_str(&self) -> &str {
        path(&self.remote)
    }
}

fn commit_author() -> LocalCommitAuthor {
    LocalCommitAuthor {
        git_actor: "Harness Bot <bot@example.com> 1711390800 +0000".into(),
    }
}

fn update_ref(remote: &Path, reference: &str, target: &str) {
    run_git(remote, &["update-ref", reference, target]);
}

fn run_git(dir: &Path, args: &[&str]) {
    let output = git_command(dir, args).output().expect("run git");
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn git_stdout(dir: &Path, args: &[&str]) -> String {
    let output = git_command(dir, args).output().expect("run git");
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn git_command(dir: &Path, args: &[&str]) -> Command {
    let mut command = Command::new("git");
    if dir.join("HEAD").is_file() && dir.join("objects").is_dir() && !dir.join(".git").exists() {
        command.args(["--git-dir"]).arg(dir);
    } else {
        command.args(["-C"]).arg(dir);
    }
    command.args(args);
    command
}

fn path(value: &Path) -> &str {
    value.to_str().expect("utf-8 path")
}
