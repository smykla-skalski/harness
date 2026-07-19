use std::path::Path;
use std::sync::Mutex;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::{
    GitHubAutomationClient, GitHubBranchState, GitHubCreatePullRequest, GitHubMergeEvidence,
    GitHubMergeMethod, GitHubProjectConfig, GitHubPullRequestHandle,
};

use super::{git_ref, git_ref_exists, git_tree, remote_repo_path, run_git};

pub(super) struct FakeGitHubClient {
    pub(super) pull_request: GitHubPullRequestHandle,
    pub(super) evidence: GitHubMergeEvidence,
    pub(super) create_calls: Mutex<usize>,
    pub(super) publish_calls: Mutex<usize>,
    pub(super) ready_calls: Mutex<usize>,
    pub(super) reviewer_requests: Mutex<Vec<(Vec<String>, Vec<String>)>>,
    pub(super) merge_calls: Mutex<usize>,
    pub(super) ready_error: Mutex<Option<String>>,
    pub(super) parent_interleaving: Mutex<Option<String>>,
}

#[async_trait::async_trait]
impl GitHubAutomationClient for FakeGitHubClient {
    async fn get_branch_state(
        &self,
        config: &GitHubProjectConfig,
        branch: &str,
    ) -> Result<Option<GitHubBranchState>, CliError> {
        let remote = remote_repo_path(config.checkout_path.as_path());
        let reference = format!("refs/heads/{branch}");
        if !git_ref_exists(&remote, &reference) {
            return Ok(None);
        }
        Ok(Some(GitHubBranchState {
            commit_sha: git_ref(&remote, &reference),
            tree_sha: git_tree(&remote, &reference),
        }))
    }

    async fn publish_branch_from_worktree(
        &self,
        config: &GitHubProjectConfig,
        worktree: &Path,
        branch: &str,
    ) -> Result<(), CliError> {
        self.publish_branch_from_worktree_at_parent(config, worktree, branch, None)
            .await
    }

    async fn publish_branch_from_worktree_at_parent(
        &self,
        config: &GitHubProjectConfig,
        worktree: &Path,
        branch: &str,
        expected_parent: Option<&str>,
    ) -> Result<(), CliError> {
        let remote = remote_repo_path(config.checkout_path.as_path());
        if let Some(interloper) = self
            .parent_interleaving
            .lock()
            .expect("parent interleaving")
            .take()
        {
            run_git(
                &remote,
                &["update-ref", &format!("refs/heads/{branch}"), &interloper],
            );
        }
        let branch_ref = format!("refs/heads/{branch}");
        let observed_parent = if git_ref_exists(&remote, &branch_ref) {
            git_ref(&remote, &branch_ref)
        } else {
            git_ref(&remote, &format!("refs/heads/{}", config.default_branch))
        };
        if expected_parent.is_some_and(|expected| expected != observed_parent) {
            return Err(CliErrorKind::invalid_transition(
                "task-board GitHub publication parent changed after preflight",
            )
            .into());
        }
        *self.publish_calls.lock().expect("publish calls") += 1;
        run_git(worktree, &["push", "origin", &format!("HEAD:{branch}")]);
        Ok(())
    }

    async fn pull_request_merge_evidence(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubMergeEvidence, CliError> {
        Ok(self.evidence.clone())
    }

    async fn get_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        Ok(self.pull_request.clone())
    }

    async fn get_pull_request_fresh(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        Ok(self.pull_request.clone())
    }

    async fn ensure_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _request: &GitHubCreatePullRequest,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        *self.create_calls.lock().expect("create calls") += 1;
        Ok(self.pull_request.clone())
    }

    async fn ready_pull_request_for_review(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        if let Some(error) = self.ready_error.lock().expect("ready error").take() {
            return Err(CliErrorKind::workflow_io(error).into());
        }
        *self.ready_calls.lock().expect("ready calls") += 1;
        let mut ready = self.pull_request.clone();
        ready.draft = false;
        Ok(ready)
    }

    async fn request_pull_request_reviewers(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
        reviewers: &[String],
        team_reviewers: &[String],
    ) -> Result<(), CliError> {
        self.reviewer_requests
            .lock()
            .expect("reviewer requests")
            .push((reviewers.to_vec(), team_reviewers.to_vec()));
        Ok(())
    }

    async fn sync_pull_request_labels(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
        _managed_labels: &[String],
        _desired_labels: &[String],
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn merge_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
        _method: GitHubMergeMethod,
        _head_sha: Option<&str>,
    ) -> Result<(), CliError> {
        *self.merge_calls.lock().expect("merge calls") += 1;
        Ok(())
    }
}
