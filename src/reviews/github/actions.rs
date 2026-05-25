use std::slice;
use std::time::Duration;

use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{GitHubCachePolicy, GitHubPriority, GitHubRequestDescriptor};
use crate::task_board::github::GitHubAutomationClient;

use super::client::ReviewsGitHubClient;
use super::mapping::{action_result, github_project_config};
use super::queries::{
    ADD_COMMENT_MUTATION, ADD_REVIEW_THREAD_MUTATION, ADD_REVIEW_THREAD_REPLY_MUTATION,
    APPROVE_MUTATION, REREQUEST_CHECK_SUITE_MUTATION, VIEWER_LOGIN_QUERY,
};
use super::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionResult, ReviewTarget, ReviewsApproveRequest,
    ReviewsAutoRequest, ReviewsCommentRequest, ReviewsFileCommentKind, ReviewsFileCommentRequest,
    ReviewsFileCommentResponse, ReviewsLabelRequest, ReviewsMergeRequest,
    ReviewsRequestReviewRequest, ReviewsRerunChecksRequest, timeline,
};

const HOURS: u64 = 60 * 60;
const DAYS: u64 = 24 * HOURS;

impl ReviewsGitHubClient {
    /// Resolve the authenticated GitHub viewer's login via the simplest
    /// `viewer { login }` GraphQL query. Used to mark "(you)" on the
    /// current viewer's reviewer pill and surface the "Commenting as
    /// @viewer" caption in the composer. Returns `None` when GitHub
    /// either rejects the call (revoked token) or returns an empty
    /// login — both are non-fatal: the UI just doesn't surface the
    /// affordances.
    pub(crate) async fn fetch_viewer_login(&self) -> Option<String> {
        let response: serde_json::Value = self
            .client
            .graphql_envelope(
                GitHubRequestDescriptor::graphql(
                    "reviews.viewer_login",
                    GitHubPriority::NormalRead,
                    GitHubCachePolicy::read_through(
                        Duration::from_secs(24 * HOURS),
                        Duration::from_secs(7 * DAYS),
                    ),
                ),
                json!({ "query": VIEWER_LOGIN_QUERY }),
            )
            .await
            .ok()?
            .body;
        let login = response
            .pointer("/data/viewer/login")
            .and_then(serde_json::Value::as_str)?
            .trim();
        if login.is_empty() {
            None
        } else {
            Some(login.to_string())
        }
    }

    pub(crate) async fn approve(
        &self,
        request: &ReviewsApproveRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = self
                .client
                .graphql_envelope(
                    mutation_descriptor("reviews.approve"),
                    json!({
                        "query": APPROVE_MUTATION,
                        "variables": {
                            "id": target.pull_request_id,
                        },
                    }),
                )
                .await;
            results.push(action_result(
                target,
                ReviewActionKind::Approve,
                result.map(|_| ()),
            ));
        }
        Ok(results)
    }

    pub(crate) async fn comment(
        &self,
        request: &ReviewsCommentRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = self
                .client
                .graphql_envelope(
                    mutation_descriptor("reviews.comment"),
                    json!({
                        "query": ADD_COMMENT_MUTATION,
                        "variables": {
                            "id": target.pull_request_id,
                            "body": request.body,
                        },
                    }),
                )
                .await
                .map(|response| response.body);
            results.push(comment_action_result(target, result));
        }
        Ok(results)
    }

    pub(crate) async fn add_file_comment(
        &self,
        request: &ReviewsFileCommentRequest,
    ) -> Result<ReviewsFileCommentResponse, CliError> {
        match request.kind {
            ReviewsFileCommentKind::NewThread => self.add_file_comment_thread(request).await,
            ReviewsFileCommentKind::Reply => self.add_file_comment_reply(request).await,
        }
    }

    async fn add_file_comment_thread(
        &self,
        request: &ReviewsFileCommentRequest,
    ) -> Result<ReviewsFileCommentResponse, CliError> {
        let response: serde_json::Value = self
            .client
            .graphql_envelope(
                mutation_descriptor("reviews.add_file_comment_thread"),
                json!({
                    "query": ADD_REVIEW_THREAD_MUTATION,
                    "variables": {
                        "pullRequestId": request.pull_request_id.as_str(),
                        "body": request.normalized_body(),
                        "path": request.path.as_deref(),
                        "line": request.line,
                        "side": request.side.as_deref(),
                    },
                }),
            )
            .await
            .map(|response| response.body)?;
        let thread_id = response
            .pointer("/data/addPullRequestReviewThread/thread/id")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string);
        let comment_id = response
            .pointer("/data/addPullRequestReviewThread/thread/comments/nodes/0/id")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string);
        let url = response
            .pointer("/data/addPullRequestReviewThread/thread/comments/nodes/0/url")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string);
        Ok(request.response(thread_id, comment_id, url))
    }

    async fn add_file_comment_reply(
        &self,
        request: &ReviewsFileCommentRequest,
    ) -> Result<ReviewsFileCommentResponse, CliError> {
        let response: serde_json::Value = self
            .client
            .graphql_envelope(
                mutation_descriptor("reviews.add_file_comment_reply"),
                json!({
                    "query": ADD_REVIEW_THREAD_REPLY_MUTATION,
                    "variables": {
                        "threadId": request.thread_id.as_deref(),
                        "body": request.normalized_body(),
                    },
                }),
            )
            .await
            .map(|response| response.body)?;
        let comment_id = response
            .pointer("/data/addPullRequestReviewThreadReply/comment/id")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string);
        let url = response
            .pointer("/data/addPullRequestReviewThreadReply/comment/url")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string);
        Ok(request.response(request.thread_id.clone(), comment_id, url))
    }

    pub(crate) async fn merge(
        &self,
        request: &ReviewsMergeRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .merge_pull_request(
                        &config,
                        target.number,
                        request.method,
                        Some(target.head_sha.as_str()),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid reviews repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(target, ReviewActionKind::Merge, result));
        }
        Ok(results)
    }

    pub(crate) async fn rerun_checks(
        &self,
        request: &ReviewsRerunChecksRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            if target.check_suite_ids.is_empty() {
                results.push(ReviewActionResult {
                    repository: target.repository.clone(),
                    number: target.number,
                    action: ReviewActionKind::RerunChecks,
                    outcome: ReviewActionOutcome::Skipped,
                    message: Some("no rerunnable check suites were available".to_string()),
                    timeline_entry: None,
                });
                continue;
            }
            let mut outcome = Ok(());
            for check_suite_id in &target.check_suite_ids {
                if let Err(error) = self
                    .client
                    .graphql_envelope(
                        mutation_descriptor("reviews.rerequest_checks"),
                        json!({
                            "query": REREQUEST_CHECK_SUITE_MUTATION,
                            "variables": {
                                "checkSuiteId": check_suite_id,
                                "repositoryId": target.repository_id,
                            },
                        }),
                    )
                    .await
                    .map(|_| ())
                {
                    outcome = Err(error);
                    break;
                }
            }
            results.push(action_result(
                target,
                ReviewActionKind::RerunChecks,
                outcome,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn add_label(
        &self,
        request: &ReviewsLabelRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .sync_pull_request_labels(
                        &config,
                        target.number,
                        &[],
                        slice::from_ref(&request.label),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid reviews repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(target, ReviewActionKind::AddLabel, result));
        }
        Ok(results)
    }

    pub(crate) async fn request_review(
        &self,
        request: &ReviewsRequestReviewRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        let reviewer = request.reviewer_login.trim().to_string();
        let reviewers = slice::from_ref(&reviewer);
        for target in &request.targets {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .request_pull_request_reviewers(&config, target.number, reviewers, &[])
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid reviews repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(
                target,
                ReviewActionKind::RequestReview,
                result,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn auto_mode(
        &self,
        request: &ReviewsAutoRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::new();
        for target in request
            .targets
            .iter()
            .filter(|target| target.is_auto_approvable())
        {
            let result = self
                .client
                .graphql_envelope(
                    mutation_descriptor("reviews.auto_approve"),
                    json!({
                        "query": APPROVE_MUTATION,
                        "variables": {
                            "id": target.pull_request_id,
                        },
                    }),
                )
                .await
                .map(|_| ());
            results.push(action_result(target, ReviewActionKind::AutoApprove, result));
        }
        for target in request
            .targets
            .iter()
            .filter(|target| target.is_auto_mergeable() || target.is_auto_approvable())
        {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .merge_pull_request(
                        &config,
                        target.number,
                        request.method,
                        Some(target.head_sha.as_str()),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid reviews repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(target, ReviewActionKind::AutoMerge, result));
        }
        Ok(results)
    }
}

fn comment_action_result(
    target: &ReviewTarget,
    result: Result<serde_json::Value, CliError>,
) -> ReviewActionResult {
    match result {
        Ok(value) => {
            let entry = value
                .pointer("/addComment/commentEdge/node")
                .or_else(|| value.pointer("/data/addComment/commentEdge/node"))
                .and_then(timeline::map_timeline_node);
            if let Some(ref e) = entry {
                timeline::append_timeline_entry_to_cache(&target.pull_request_id, e);
            }
            ReviewActionResult {
                repository: target.repository.clone(),
                number: target.number,
                action: ReviewActionKind::Comment,
                outcome: ReviewActionOutcome::Applied,
                message: None,
                timeline_entry: entry,
            }
        }
        Err(error) => ReviewActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action: ReviewActionKind::Comment,
            outcome: ReviewActionOutcome::Failed,
            message: Some(error.to_string()),
            timeline_entry: None,
        },
    }
}

fn mutation_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::graphql(
        operation,
        GitHubPriority::Mutation,
        GitHubCachePolicy::no_store(),
    )
}
