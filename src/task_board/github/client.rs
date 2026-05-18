use std::path::Path;
use std::sync::OnceLock;

use async_trait::async_trait;
use octocrab::models;
use octocrab::params;
use rustls::crypto::ring::default_provider;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::GitHubAutomationClient;
use super::config::{GitHubMergeMethod, GitHubProjectConfig};
use super::evidence::{GitHubMergeEvidence, GitHubPullRequestEvidence};
use super::evidence_api::{
    branch_protection_evidence, check_runs_for_ref, combined_status_for_sha, merge_checks,
    merge_reviews, review_thread_summary,
};
use super::publication::{
    GitHubBranchState, branch_state_async, publish_branch_from_worktree_async,
};

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitHubPullRequestHandle {
    pub number: u64,
    pub html_url: Option<String>,
    pub draft: bool,
    pub merged: bool,
    pub head_sha: String,
    pub requested_reviewers: Vec<String>,
    pub requested_team_reviewers: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubCreatePullRequest {
    pub title: String,
    pub body: Option<String>,
    pub head_branch: String,
    pub base_branch: String,
    pub draft: bool,
}

#[derive(Clone)]
pub struct GitHubApiAutomationClient {
    client: octocrab::Octocrab,
    token: String,
}

impl GitHubApiAutomationClient {
    /// Build a GitHub automation client from a token.
    ///
    /// # Errors
    /// Returns an error when the token is empty or the API client cannot be built.
    pub fn new(token: impl Into<String>) -> Result<Self, CliError> {
        let token = token.into();
        let token = token.trim();
        if token.is_empty() {
            return Err(CliErrorKind::workflow_io("task-board github token missing").into());
        }
        ensure_rustls_provider();
        let client = octocrab::Octocrab::builder()
            .personal_token(token.to_string())
            .build()
            .map_err(client_error)?;
        Ok(Self {
            client,
            token: token.to_string(),
        })
    }
}

#[async_trait]
impl GitHubAutomationClient for GitHubApiAutomationClient {
    async fn get_branch_state(
        &self,
        config: &GitHubProjectConfig,
        branch: &str,
    ) -> Result<Option<GitHubBranchState>, CliError> {
        branch_state_async(&self.client, config, branch).await
    }

    async fn publish_branch_from_worktree(
        &self,
        config: &GitHubProjectConfig,
        worktree: &Path,
        branch: &str,
    ) -> Result<(), CliError> {
        publish_branch_from_worktree_async(&self.client, config, worktree, branch, &self.token)
            .await
    }

    async fn pull_request_merge_evidence(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubMergeEvidence, CliError> {
        let pulls = self
            .client
            .pulls(config.owner.as_str(), config.repo.as_str());
        let pull_request = pulls
            .get(pull_request_number)
            .await
            .map_err(operation_error)?;
        let files = self
            .client
            .all_pages(
                pulls
                    .list_files(pull_request_number)
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        let reviews = self
            .client
            .all_pages(
                pulls
                    .list_reviews(pull_request_number)
                    .per_page(100_u8)
                    .send()
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        let head_sha = pull_request.head.sha.clone();
        let combined_status = combined_status_for_sha(&self.client, config, &head_sha)
            .await
            .map_err(operation_error)?;
        let check_runs = check_runs_for_ref(&self.client, config, &head_sha)
            .await
            .map_err(operation_error)?;
        let branch_protection = branch_protection_evidence(&self.client, config, &pull_request)
            .await
            .map_err(operation_error)?;
        let review_threads = review_thread_summary(&self.client, config, &pull_request)
            .await
            .map_err(operation_error)?;
        Ok(GitHubMergeEvidence {
            pull_request: GitHubPullRequestEvidence {
                number: pull_request.number,
                html_url: Some(pull_request.html_url.to_string()),
                base_branch: pull_request.base.ref_field.clone(),
                head_branch: pull_request.head.ref_field.clone(),
                draft: pull_request.draft.unwrap_or(false),
                changed_paths: files.into_iter().map(|entry| entry.filename).collect(),
            },
            checks: merge_checks(combined_status.statuses, check_runs),
            reviews: merge_reviews(reviews, &review_threads),
            branch_protection,
        })
    }

    async fn get_pull_request(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        self.client
            .pulls(config.owner.as_str(), config.repo.as_str())
            .get(pull_request_number)
            .await
            .map(|pull_request| handle_from_pull_request(&pull_request))
            .map_err(operation_error)
    }

    async fn ensure_pull_request(
        &self,
        config: &GitHubProjectConfig,
        request: &GitHubCreatePullRequest,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        let pulls = self
            .client
            .pulls(config.owner.as_str(), config.repo.as_str());
        let existing = self
            .client
            .all_pages(
                pulls
                    .list()
                    .state(params::State::Open)
                    .head(format!("{}:{}", config.owner, request.head_branch))
                    .per_page(100_u8)
                    .send()
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        if let Some(existing) = existing.into_iter().next() {
            return Ok(handle_from_simple_pull_request(&existing));
        }
        let mut builder = pulls
            .create(
                request.title.clone(),
                request.head_branch.clone(),
                request.base_branch.clone(),
            )
            .draft(request.draft);
        if let Some(body) = request.body.as_deref() {
            builder = builder.body(body);
        }
        builder
            .send()
            .await
            .map(|pull_request| handle_from_pull_request(&pull_request))
            .map_err(operation_error)
    }

    async fn ready_pull_request_for_review(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        let route = format!(
            "/repos/{owner}/{repo}/pulls/{pull_request_number}/ready_for_review",
            owner = config.owner,
            repo = config.repo,
        );
        let _: serde_json::Value = self
            .client
            .post(route, None::<&()>)
            .await
            .map_err(operation_error)?;
        self.get_pull_request(config, pull_request_number).await
    }

    async fn request_pull_request_reviewers(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        reviewers: &[String],
        team_reviewers: &[String],
    ) -> Result<(), CliError> {
        self.client
            .pulls(config.owner.as_str(), config.repo.as_str())
            .request_reviews(
                pull_request_number,
                reviewers.to_vec(),
                team_reviewers.to_vec(),
            )
            .await
            .map(|_| ())
            .map_err(operation_error)
    }

    async fn sync_pull_request_labels(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        managed_labels: &[String],
        desired_labels: &[String],
    ) -> Result<(), CliError> {
        let issues = self
            .client
            .issues(config.owner.as_str(), config.repo.as_str());
        let current_labels = self
            .client
            .all_pages(
                issues
                    .list_labels_for_issue(pull_request_number)
                    .per_page(100_u8)
                    .send()
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        let managed = managed_labels
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let mut labels = current_labels
            .into_iter()
            .map(|label| label.name)
            .filter(|label| !managed.contains(&label.as_str()))
            .collect::<Vec<_>>();
        labels.extend(desired_labels.iter().cloned());
        labels.sort();
        labels.dedup();
        issues
            .replace_all_labels(pull_request_number, &labels)
            .await
            .map_err(operation_error)?;
        Ok(())
    }

    async fn merge_pull_request(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        method: GitHubMergeMethod,
        head_sha: Option<&str>,
    ) -> Result<(), CliError> {
        let pulls = self
            .client
            .pulls(config.owner.as_str(), config.repo.as_str());
        let mut builder = pulls.merge(pull_request_number).method(match method {
            GitHubMergeMethod::Squash => params::pulls::MergeMethod::Squash,
            GitHubMergeMethod::Merge => params::pulls::MergeMethod::Merge,
            GitHubMergeMethod::Rebase => params::pulls::MergeMethod::Rebase,
        });
        if let Some(head_sha) = head_sha {
            builder = builder.sha(head_sha.to_string());
        }
        let response = builder.send().await.map_err(operation_error)?;
        if response.merged {
            return Ok(());
        }
        Err(CliErrorKind::workflow_io(format!(
            "task-board github merge rejected: {}",
            response
                .message
                .unwrap_or_else(|| "no merge rejection message returned".to_string())
        ))
        .into())
    }
}

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}

fn handle_from_pull_request(pull_request: &models::pulls::PullRequest) -> GitHubPullRequestHandle {
    build_pull_request_handle(
        pull_request.number,
        pull_request.html_url.to_string(),
        pull_request.draft.unwrap_or(false),
        pull_request.merged,
        pull_request.head.sha.clone(),
        pull_request
            .requested_reviewers
            .iter()
            .map(|reviewer| reviewer.login.clone())
            .collect(),
        pull_request
            .requested_teams
            .iter()
            .map(|team| team.slug.clone())
            .collect(),
    )
}

fn handle_from_simple_pull_request(
    pull_request: &models::pulls::SimplePullRequest,
) -> GitHubPullRequestHandle {
    build_pull_request_handle(
        pull_request.number,
        pull_request.html_url.to_string(),
        pull_request.draft.unwrap_or(false),
        pull_request.merged_at.is_some(),
        pull_request.head.sha.clone(),
        pull_request
            .requested_reviewers
            .iter()
            .map(|reviewer| reviewer.login.clone())
            .collect(),
        pull_request
            .requested_teams
            .iter()
            .map(|team| team.slug.clone())
            .collect(),
    )
}

fn build_pull_request_handle(
    number: u64,
    html_url: String,
    draft: bool,
    merged: bool,
    head_sha: String,
    requested_reviewers: Vec<String>,
    requested_team_reviewers: Vec<String>,
) -> GitHubPullRequestHandle {
    GitHubPullRequestHandle {
        number,
        html_url: Some(html_url),
        draft,
        merged,
        head_sha,
        requested_reviewers,
        requested_team_reviewers,
    }
}

fn client_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "create task-board github automation client: {error}"
    )))
    .with_source(error)
}

fn operation_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "task-board github automation failed: {error}"
    )))
    .with_source(error)
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::thread;

    use serde_json::json;

    use super::*;

    #[derive(Debug, Default)]
    struct CapturedRequest {
        path: String,
        body: String,
    }

    #[tokio::test]
    async fn request_pull_request_reviewers_posts_expected_payload() {
        let (endpoint, captured, handle) = spawn_json_mock(json!({
            "id": 1,
            "node_id": "PRR_1",
            "html_url": "https://github.invalid/owner/repo/pull/42#pullrequestreview-1",
            "user": null
        }));
        let client = automation_client_with_base_uri(endpoint);
        let config = GitHubProjectConfig::new("owner", "repo", PathBuf::from("."));

        client
            .request_pull_request_reviewers(
                &config,
                42,
                &["alice".to_string(), "bob".to_string()],
                &["core".to_string()],
            )
            .await
            .expect("request reviewers");

        handle.join().expect("mock server");
        let captured = captured.lock().expect("captured request");
        assert_eq!(
            captured.path,
            "/repos/owner/repo/pulls/42/requested_reviewers"
        );
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&captured.body).expect("json body"),
            json!({
                "reviewers": ["alice", "bob"],
                "team_reviewers": ["core"]
            })
        );
    }

    #[test]
    fn handle_from_simple_pull_request_maps_listing_entries() {
        let pull_request: models::pulls::SimplePullRequest =
            serde_json::from_value(json!({
                "url": "https://api.github.invalid/repos/owner/repo/pulls/42",
                "id": 42,
                "node_id": "PR_kwDOExample",
                "html_url": "https://github.invalid/owner/repo/pull/42",
                "diff_url": "https://github.invalid/owner/repo/pull/42.diff",
                "patch_url": "https://github.invalid/owner/repo/pull/42.patch",
                "issue_url": "https://api.github.invalid/repos/owner/repo/issues/42",
                "commits_url": "https://api.github.invalid/repos/owner/repo/pulls/42/commits",
                "review_comments_url": "https://api.github.invalid/repos/owner/repo/pulls/comments{/number}",
                "review_comment_url": "https://api.github.invalid/repos/owner/repo/pulls/comments{/number}",
                "comments_url": "https://api.github.invalid/repos/owner/repo/issues/42/comments",
                "statuses_url": "https://api.github.invalid/repos/owner/repo/statuses/deadbeef",
                "number": 42,
                "state": "open",
                "locked": false,
                "title": "Keep existing pull request",
                "user": simple_user_json("author", 1),
                "body": null,
                "labels": [],
                "milestone": null,
                "active_lock_reason": null,
                "created_at": "2026-05-18T00:00:00Z",
                "updated_at": "2026-05-18T00:00:00Z",
                "closed_at": null,
                "merged_at": null,
                "merge_commit_sha": null,
                "assignee": null,
                "assignees": null,
                "requested_reviewers": [simple_user_json("reviewer", 2)],
                "requested_teams": [],
                "head": {
                    "label": null,
                    "ref": "feature-branch",
                    "sha": "deadbeef",
                    "user": null,
                    "repo": null
                },
                "base": {
                    "label": null,
                    "ref": "main",
                    "sha": "cafebabe",
                    "user": null,
                    "repo": null
                },
                "_links": {},
                "author_association": "MEMBER",
                "auto_merge": null,
                "draft": true
            }))
            .expect("simple pull request");

        let handle = handle_from_simple_pull_request(&pull_request);

        assert_eq!(
            handle,
            GitHubPullRequestHandle {
                number: 42,
                html_url: Some("https://github.invalid/owner/repo/pull/42".into()),
                draft: true,
                merged: false,
                head_sha: "deadbeef".into(),
                requested_reviewers: vec!["reviewer".into()],
                requested_team_reviewers: vec![],
            }
        );
    }

    fn automation_client_with_base_uri(base_uri: String) -> GitHubApiAutomationClient {
        ensure_rustls_provider();
        let client = octocrab::Octocrab::builder()
            .personal_token("token".to_string())
            .base_uri(base_uri)
            .expect("base uri")
            .build()
            .expect("octocrab client");
        GitHubApiAutomationClient {
            client,
            token: "token".to_string(),
        }
    }

    fn spawn_json_mock(
        response_body: serde_json::Value,
    ) -> (String, Arc<Mutex<CapturedRequest>>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let captured = Arc::new(Mutex::new(CapturedRequest::default()));
        let captured_clone = Arc::clone(&captured);
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            *captured_clone.lock().expect("captured request") = capture_request(&request);
            write_http_response(&mut stream, response_body.to_string().as_str());
        });
        (endpoint, captured, handle)
    }

    fn simple_user_json(login: &str, id: u64) -> serde_json::Value {
        let base = format!("https://api.github.invalid/users/{login}");
        json!({
            "name": null,
            "email": null,
            "login": login,
            "id": id,
            "node_id": format!("MDQ6VXNlcj{id}"),
            "avatar_url": format!("{base}/avatar"),
            "gravatar_id": "",
            "url": base,
            "html_url": format!("https://github.invalid/{login}"),
            "followers_url": format!("{base}/followers"),
            "following_url": format!("{base}/following{{/other_user}}"),
            "gists_url": format!("{base}/gists{{/gist_id}}"),
            "starred_url": format!("{base}/starred{{/owner}}{{/repo}}"),
            "subscriptions_url": format!("{base}/subscriptions"),
            "organizations_url": format!("{base}/orgs"),
            "repos_url": format!("{base}/repos"),
            "events_url": format!("{base}/events{{/privacy}}"),
            "received_events_url": format!("{base}/received_events"),
            "type": "User",
            "site_admin": false,
            "starred_at": null,
            "user_view_type": null
        })
    }

    fn capture_request(request: &str) -> CapturedRequest {
        let path = request
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .unwrap_or_default()
            .to_string();
        let body = request
            .split("\r\n\r\n")
            .nth(1)
            .unwrap_or_default()
            .to_string();
        CapturedRequest { path, body }
    }

    fn read_http_request(stream: &mut TcpStream) -> String {
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(1)))
            .expect("read timeout");
        let mut buffer = Vec::new();
        loop {
            let mut chunk = [0_u8; 1024];
            let read = stream.read(&mut chunk).expect("read request");
            if read == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..read]);
            let request = String::from_utf8_lossy(&buffer);
            if headers_and_body_complete(request.as_ref()) {
                break;
            }
        }
        String::from_utf8(buffer).expect("utf8 request")
    }

    fn headers_and_body_complete(request: &str) -> bool {
        let Some((headers, body)) = request.split_once("\r\n\r\n") else {
            return false;
        };
        let content_length = headers
            .lines()
            .find_map(|line| {
                line.split_once(':').and_then(|(name, value)| {
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
            })
            .unwrap_or(0);
        body.len() >= content_length
    }

    fn write_http_response(stream: &mut TcpStream, body: &str) {
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream
            .write_all(response.as_bytes())
            .expect("write response");
        stream.flush().expect("flush response");
    }
}
