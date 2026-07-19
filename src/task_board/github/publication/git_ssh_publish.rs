use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use gix::actor::{Signature, SignatureRef};
use gix::bstr::ByteSlice;
use gix::objs::WriteTo;
use gix::{ObjectId, objs};
use tokio::task::spawn_blocking;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::begin_external_mutation;
use crate::sandbox;
use crate::task_board::github::GitHubProjectConfig;

use super::signing::{
    native_git_transport_required_error, publication_signature, rest_commit_signature_boundary,
    unsigned_commit_payload,
};
use super::ssh_signing;
use super::types::{
    BranchPublicationMode, LocalBranchSnapshot, NativeGitTransportReason,
    RestCommitSignatureBoundary,
};

#[cfg(test)]
#[path = "git_ssh_publish_race_tests.rs"]
mod race_tests;

const PUBLICATION_OPERATION: &str = "task_board.github.publish_branch";

pub(super) async fn publish_native_branch(
    config: &GitHubProjectConfig,
    worktree: &Path,
    branch: &str,
    github_token: &str,
    snapshot: &LocalBranchSnapshot,
    mode: &BranchPublicationMode,
) -> Result<(), CliError> {
    let plan = GitPublishPlan::new(config, worktree, branch, github_token, snapshot, mode)?;
    run_native_publication_worker(move || plan.publish()).await
}

pub(super) async fn run_native_publication_worker(
    publish: impl FnOnce() -> Result<(), CliError> + Send + 'static,
) -> Result<(), CliError> {
    let mut mutation = begin_external_mutation(PUBLICATION_OPERATION).await;
    spawn_blocking(move || {
        let result = publish();
        if result.is_ok() {
            mutation.mark_remote_success();
        }
        result
    })
    .await
    .unwrap_or_else(|error| {
        Err(CliErrorKind::workflow_io(format!(
            "task-board github SSH git publisher worker failed: {error}"
        ))
        .into())
    })
}

struct GitPublishPlan {
    worktree: PathBuf,
    remote_url: String,
    auth_header: String,
    fetch_ref: String,
    push_lease: String,
    push_refspec_prefix: String,
    commit_payload: Vec<u8>,
}

impl GitPublishPlan {
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
        Ok(Self {
            worktree: worktree_scope.path().to_path_buf(),
            remote_url,
            auth_header: github_auth_header(github_token)?,
            fetch_ref: branch_head_ref(parent_branch),
            push_lease: branch_push_lease(branch, mode),
            push_refspec_prefix: branch_push_refspec_prefix(branch),
            commit_payload: native_commit_payload(snapshot, mode.parent_sha())?,
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
            [
                "push",
                self.push_lease.as_str(),
                self.remote_url.as_str(),
                refspec.as_str(),
            ],
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

fn native_commit_payload(
    snapshot: &LocalBranchSnapshot,
    parent_sha: &str,
) -> Result<Vec<u8>, CliError> {
    match rest_commit_signature_boundary(&snapshot.profile, snapshot.existing_signature.as_ref())? {
        RestCommitSignatureBoundary::RestSupported => {
            rest_supported_native_commit_payload(snapshot, parent_sha)
        }
        RestCommitSignatureBoundary::NativeGitTransportRequired(
            NativeGitTransportReason::ConfiguredSshSigning,
        ) => Ok(ssh_signing::native_ssh_commit_object(
            snapshot,
            snapshot.head_tree_sha.as_str(),
            parent_sha,
        )?
        .commit_payload),
        RestCommitSignatureBoundary::NativeGitTransportRequired(reason) => {
            Err(native_git_transport_required_error(reason))
        }
    }
}

fn rest_supported_native_commit_payload(
    snapshot: &LocalBranchSnapshot,
    parent_sha: &str,
) -> Result<Vec<u8>, CliError> {
    let unsigned_payload = unsigned_commit_payload(snapshot, &snapshot.head_tree_sha, parent_sha);
    let signature = publication_signature(
        &snapshot.profile,
        snapshot.existing_signature.as_ref(),
        unsigned_payload.as_bytes(),
    )?;
    let extra_headers = signature.map_or_else(Vec::new, |signature| {
        vec![("gpgsig".into(), signature.as_bytes().as_bstr().into())]
    });
    let commit = objs::Commit {
        tree: object_id_from_hex(snapshot.head_tree_sha.as_str(), "tree")?,
        parents: [object_id_from_hex(parent_sha, "parent")?]
            .into_iter()
            .collect(),
        author: actor_signature(snapshot.author.git_actor.as_str(), "author")?,
        committer: actor_signature(snapshot.committer.git_actor.as_str(), "committer")?,
        encoding: None,
        message: snapshot.commit_message.as_str().into(),
        extra_headers,
    };
    let mut commit_payload = Vec::new();
    commit.write_to(&mut commit_payload).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github serialize commit object: {error}"
        ))
    })?;
    Ok(commit_payload)
}

fn object_id_from_hex(hex: &str, label: &str) -> Result<ObjectId, CliError> {
    ObjectId::from_hex(hex.as_bytes()).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github parse native commit {label} sha '{hex}': {error}"
        ))
        .into()
    })
}

fn actor_signature(actor: &str, label: &str) -> Result<Signature, CliError> {
    SignatureRef::from_bytes(actor.as_bytes())
        .map(Into::into)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "task-board github parse native commit {label}: {error}"
            ))
            .into()
        })
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

fn branch_push_lease(branch: &str, mode: &BranchPublicationMode) -> String {
    let reference = branch_head_ref(branch);
    match mode {
        BranchPublicationMode::Create { .. } => format!("--force-with-lease={reference}:"),
        BranchPublicationMode::Update { parent_sha } => {
            format!("--force-with-lease={reference}:{parent_sha}")
        }
    }
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
#[path = "git_ssh_publish_tests.rs"]
mod tests;
