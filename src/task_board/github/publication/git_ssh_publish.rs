use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use tokio::task::spawn_blocking;

use crate::errors::{CliError, CliErrorKind};
use crate::sandbox;
use crate::task_board::github::GitHubProjectConfig;

use super::ssh_signing;
use super::types::{BranchPublicationMode, LocalBranchSnapshot};

pub(super) async fn publish_configured_ssh_branch(
    config: &GitHubProjectConfig,
    worktree: &Path,
    branch: &str,
    github_token: &str,
    snapshot: &LocalBranchSnapshot,
    mode: &BranchPublicationMode,
) -> Result<(), CliError> {
    let plan = GitSshPublishPlan::new(config, worktree, branch, github_token, snapshot, mode)?;
    spawn_blocking(move || plan.publish())
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "task-board github SSH git publisher worker failed: {error}"
            ))
            .into())
        })
}

struct GitSshPublishPlan {
    worktree: PathBuf,
    remote_url: String,
    auth_header: String,
    fetch_ref: String,
    push_refspec_prefix: String,
    commit_payload: Vec<u8>,
}

impl GitSshPublishPlan {
    fn new(
        config: &GitHubProjectConfig,
        worktree: &Path,
        branch: &str,
        github_token: &str,
        snapshot: &LocalBranchSnapshot,
        mode: &BranchPublicationMode,
    ) -> Result<Self, CliError> {
        validate_branch_name(branch)?;
        let worktree_scope = sandbox::resolve_project_input(worktree.to_string_lossy().as_ref())?;
        let remote_url = github_https_url(config)?;
        let parent_branch = match mode {
            BranchPublicationMode::Create { .. } => config.default_branch.as_str(),
            BranchPublicationMode::Update { .. } => branch,
        };
        validate_branch_name(parent_branch)?;
        let native_commit = ssh_signing::native_ssh_commit_object(
            snapshot,
            snapshot.head_tree_sha.as_str(),
            mode.parent_sha(),
        )?;
        Ok(Self {
            worktree: worktree_scope.path().to_path_buf(),
            remote_url,
            auth_header: github_auth_header(github_token)?,
            fetch_ref: branch_head_ref(parent_branch),
            push_refspec_prefix: branch_push_refspec_prefix(branch),
            commit_payload: native_commit.commit_payload,
        })
    }

    fn publish(&self) -> Result<(), CliError> {
        self.git_output(
            [
                "fetch",
                "--no-tags",
                self.remote_url.as_str(),
                self.fetch_ref.as_str(),
            ],
            None,
            true,
        )?;
        let commit_sha = self.write_commit_object()?;
        let refspec = format!("{}{}", commit_sha, self.push_refspec_prefix);
        self.git_output(
            ["push", self.remote_url.as_str(), refspec.as_str()],
            None,
            true,
        )?;
        Ok(())
    }

    fn write_commit_object(&self) -> Result<String, CliError> {
        let output = self.git_output(
            ["hash-object", "-t", "commit", "-w", "--stdin"],
            Some(&self.commit_payload),
            false,
        )?;
        let commit_sha = String::from_utf8_lossy(&output.stdout).trim().to_string();
        validate_object_id(commit_sha.as_str())?;
        Ok(commit_sha)
    }

    fn git_output<const N: usize>(
        &self,
        args: [&str; N],
        stdin: Option<&[u8]>,
        authenticate: bool,
    ) -> Result<Output, CliError> {
        let mut command = Command::new("git");
        command
            .arg("-C")
            .arg(&self.worktree)
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if authenticate {
            command
                .env("GIT_CONFIG_COUNT", "1")
                .env("GIT_CONFIG_KEY_0", "http.extraheader")
                .env("GIT_CONFIG_VALUE_0", &self.auth_header);
        }
        let mut child = command.spawn().map_err(|error| {
            CliErrorKind::workflow_io(format!("task-board github run git: {error}"))
        })?;
        if let Some(input) = stdin {
            let mut child_stdin = child
                .stdin
                .take()
                .ok_or_else(|| CliErrorKind::workflow_io("task-board github open git stdin"))?;
            child_stdin.write_all(input).map_err(|error| {
                CliErrorKind::workflow_io(format!("task-board github write git stdin: {error}"))
            })?;
        }
        let output = child.wait_with_output().map_err(|error| {
            CliErrorKind::workflow_io(format!("task-board github wait for git: {error}"))
        })?;
        if output.status.success() {
            return Ok(output);
        }
        Err(CliErrorKind::workflow_io(format!(
            "task-board github git {} failed with status {}: {}",
            args[0],
            output.status,
            stderr_tail(&output.stderr)
        ))
        .into())
    }
}

fn github_https_url(config: &GitHubProjectConfig) -> Result<String, CliError> {
    validate_repository_part("owner", config.owner.as_str())?;
    validate_repository_part("repo", config.repo.as_str())?;
    Ok(format!(
        "https://github.com/{}/{}.git",
        config.owner, config.repo
    ))
}

fn github_auth_header(token: &str) -> Result<String, CliError> {
    let token = token.trim();
    if token.is_empty() || token.contains(['\n', '\r']) {
        return Err(CliErrorKind::workflow_io("task-board github token missing").into());
    }
    Ok(format!("Authorization: Bearer {token}"))
}

fn branch_head_ref(branch: &str) -> String {
    format!("refs/heads/{branch}")
}

fn branch_push_refspec_prefix(branch: &str) -> String {
    format!(":refs/heads/{branch}")
}

fn validate_repository_part(label: &str, value: &str) -> Result<(), CliError> {
    if value.is_empty() || value.contains(['/', ':', '\n', '\r']) || value.starts_with('-') {
        return Err(CliErrorKind::workflow_io(format!(
            "task-board github invalid repository {label}"
        ))
        .into());
    }
    Ok(())
}

fn validate_branch_name(branch: &str) -> Result<(), CliError> {
    if branch.is_empty()
        || branch.starts_with(['-', '/', '.'])
        || branch.ends_with(['/', '.'])
        || branch.contains([':', '\\', ' ', '~', '^', '?', '*', '[', '\n', '\r'])
        || branch.contains("..")
        || branch.contains("//")
        || branch.contains("@{")
    {
        return Err(CliErrorKind::workflow_io(format!(
            "task-board github invalid branch name '{branch}'"
        ))
        .into());
    }
    Ok(())
}

fn validate_object_id(value: &str) -> Result<(), CliError> {
    if value.len() == 40 && value.chars().all(|character| character.is_ascii_hexdigit()) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "task-board github git returned invalid commit sha '{value}'"
    ))
    .into())
}

fn stderr_tail(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    let tail = text.lines().rev().take(8).collect::<Vec<_>>();
    tail.into_iter().rev().collect::<Vec<_>>().join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
