use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command as TestCommand;

use super::super::types::LocalCommitAuthor;
use super::*;
use crate::task_board::{
    TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
};

const ED25519_PRIVATE_KEY: &str = r#"
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCzPq7zfqLffKoBDe/eo04kH2XxtSmk9D7RQyf1xUqrYgAAAJgAIAxdACAM
XQAAAAtzc2gtZWQyNTUxOQAAACCzPq7zfqLffKoBDe/eo04kH2XxtSmk9D7RQyf1xUqrYg
AAAEC2BsIi0QwW2uFscKTUUXNHLsYX4FxlaSDSblbAj7WR7bM+rvN+ot98qgEN796jTiQf
ZfG1KaT0PtFDJ/XFSqtiAAAAEHVzZXJAZXhhbXBsZS5jb20BAgMEBQ==
-----END OPENSSH PRIVATE KEY-----
"#;

#[test]
fn github_auth_header_keeps_token_out_of_arguments() {
    let header = github_auth_header(" ghp_secret ").expect("auth header");

    assert_eq!(header, "Authorization: Bearer ghp_secret");
}

#[test]
fn branch_validation_rejects_refspec_injection() {
    for branch in ["", "-bad", "bad:ref", "bad..ref", "bad ref", "bad@{ref}"] {
        assert!(validate_branch_name(branch).is_err(), "{branch}");
    }
    assert!(validate_branch_name("feature/task-board/ssh").is_ok());
}

#[test]
fn github_https_url_uses_plain_remote_without_token() {
    let config = GitHubProjectConfig::new("owner", "repo", PathBuf::new());

    let url = github_https_url(&config).expect("url");

    assert_eq!(url, "https://github.com/owner/repo.git");
    assert!(!url.contains("token"));
}

#[test]
fn push_refspec_targets_branch_with_supplied_commit_sha() {
    let prefix = branch_push_refspec_prefix("feature/one");

    assert_eq!(
        format!("{}{}", "0123456789012345678901234567890123456789", prefix),
        "0123456789012345678901234567890123456789:refs/heads/feature/one"
    );
}

#[test]
fn push_leases_use_exact_update_oid_and_empty_create_expectation() {
    let update = BranchPublicationMode::Update {
        parent_sha: "0123456789012345678901234567890123456789".into(),
    };
    let create = BranchPublicationMode::Create {
        parent_sha: "abcdefabcdefabcdefabcdefabcdefabcdefabcd".into(),
    };

    assert_eq!(
        branch_push_lease("feature/one", &update),
        "--force-with-lease=refs/heads/feature/one:0123456789012345678901234567890123456789"
    );
    assert_eq!(
        branch_push_lease("feature/one", &create),
        "--force-with-lease=refs/heads/feature/one:"
    );
}

#[test]
fn publishes_ssh_signed_commit_from_configured_key_path_to_local_bare_remote() {
    let temp = tempfile::tempdir().expect("tempdir");
    let worktree = temp.path().join("worktree");
    let remote = temp.path().join("remote.git");
    let key_path = temp.path().join("signing-key");
    fs::write(&key_path, ED25519_PRIVATE_KEY.trim_start()).expect("write key");
    seed_worktree_and_remote(&worktree, &remote);
    let parent_sha = git_stdout(&remote, &["rev-parse", "refs/heads/main"]);
    let tree_sha = git_stdout(&worktree, &["rev-parse", "HEAD^{tree}"]);
    let snapshot = branch_snapshot(tree_sha, key_path.as_path());
    let commit = ssh_signing::native_ssh_commit_object(
        &snapshot,
        snapshot.head_tree_sha.as_str(),
        parent_sha.as_str(),
    )
    .expect("ssh commit");
    let plan = GitPublishPlan {
        worktree: fs::canonicalize(&worktree).expect("canonical worktree"),
        remote_url: remote.display().to_string(),
        auth_header: github_auth_header("local-token").expect("auth header"),
        fetch_ref: branch_head_ref("main"),
        push_lease: branch_push_lease(
            "feature/ssh-signed",
            &BranchPublicationMode::Create {
                parent_sha: parent_sha.clone(),
            },
        ),
        push_refspec_prefix: branch_push_refspec_prefix("feature/ssh-signed"),
        commit_payload: commit.commit_payload,
    };

    plan.publish().expect("publish local bare remote");

    let published_sha = git_stdout(&remote, &["rev-parse", "refs/heads/feature/ssh-signed"]);
    let published_object = git_stdout(&remote, &["cat-file", "-p", published_sha.as_str()]);
    let published_tree = git_stdout(&remote, &["rev-parse", "feature/ssh-signed^{tree}"]);
    assert_eq!(published_tree, snapshot.head_tree_sha);
    assert!(published_object.contains("BEGIN SSH SIGNATURE"));
}

fn seed_worktree_and_remote(worktree: &Path, remote: &Path) {
    fs::create_dir_all(worktree).expect("create worktree");
    run_git(worktree, &["init", "-b", "main"]);
    run_git(worktree, &["config", "user.email", "test@example.com"]);
    run_git(worktree, &["config", "user.name", "Harness Test"]);
    fs::write(worktree.join("README.md"), b"seed\n").expect("write seed");
    run_git(worktree, &["add", "README.md"]);
    run_git(
        worktree,
        &["-c", "commit.gpgsign=false", "commit", "-m", "seed"],
    );
    run_git(worktree, &["init", "--bare", remote_as_str(remote)]);
    run_git(
        worktree,
        &["push", remote_as_str(remote), "HEAD:refs/heads/main"],
    );
}

fn branch_snapshot(tree_sha: String, key_path: &Path) -> LocalBranchSnapshot {
    LocalBranchSnapshot {
        head_tree_sha: tree_sha,
        commit_message: "publish signed task board state".into(),
        author: commit_author(),
        committer: commit_author(),
        profile: TaskBoardGitRuntimeProfile {
            signing: TaskBoardGitSigningConfig {
                mode: TaskBoardGitSigningMode::Ssh,
                ssh_key_path: Some(key_path.display().to_string()),
                ..Default::default()
            },
            ..Default::default()
        },
        existing_signature: None,
    }
}

fn commit_author() -> LocalCommitAuthor {
    LocalCommitAuthor {
        git_actor: "Harness Bot <bot@example.com> 1711390800 +0000".into(),
    }
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

fn git_command(dir: &Path, args: &[&str]) -> TestCommand {
    let mut command = TestCommand::new("git");
    if dir.join("HEAD").is_file() && dir.join("objects").is_dir() && !dir.join(".git").exists() {
        command.args(["--git-dir"]).arg(dir);
    } else {
        command.args(["-C"]).arg(dir);
    }
    command.args(args);
    command
}

fn remote_as_str(remote: &Path) -> &str {
    remote.to_str().expect("utf-8 remote path")
}
