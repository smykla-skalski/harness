use std::slice;

use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationClient, GitHubMergeMethod,
};

use super::client::ReviewsGitHubClient;
use super::mapping::{action_result, github_project_config};
use super::queries::{
    ADD_COMMENT_MUTATION, ADD_REVIEW_THREAD_MUTATION, ADD_REVIEW_THREAD_REPLY_MUTATION,
    APPROVE_MUTATION, REREQUEST_CHECK_SUITE_MUTATION,
};
use super::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionResult, ReviewTarget, ReviewsApproveRequest,
    ReviewsCommentRequest, ReviewsFileCommentKind, ReviewsFileCommentRequest,
    ReviewsFileCommentResponse, ReviewsLabelRequest, ReviewsMergeRequest,
    ReviewsRequestReviewRequest, ReviewsRerunChecksRequest, timeline,
};

const DIRECT_APPROVAL_OPERATION: &str = "reviews.approve";
const POLICY_APPROVAL_OPERATION: &str = "reviews.auto_approve";

impl ReviewsGitHubClient {
    /// Resolve the authenticated GitHub viewer through the shared GitHub data
    /// source. Used to mark "(you)" on the current viewer's reviewer pill and
    /// surface the "Commenting as @viewer" caption in the composer. Failures
    /// remain non-fatal: the UI simply omits those affordances.
    pub(crate) async fn fetch_viewer_login(&self) -> Option<String> {
        self.client.viewer_login().await.ok()
    }

    pub(crate) async fn approve(
        &self,
        request: &ReviewsApproveRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = approve_target(&self.client, target, DIRECT_APPROVAL_OPERATION).await;
            results.push(action_result(target, ReviewActionKind::Approve, result));
        }
        Ok(results)
    }

    pub(crate) async fn policy_approve(&self, target: &ReviewTarget) -> Result<(), CliError> {
        approve_target(&self.client, target, POLICY_APPROVAL_OPERATION).await
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
            let result = merge_target(&self.automation, target, request.method).await;
            results.push(action_result(target, ReviewActionKind::Merge, result));
        }
        Ok(results)
    }

    pub(crate) async fn policy_merge(
        &self,
        target: &ReviewTarget,
        method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        merge_target(&self.automation, target, method).await
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

async fn approve_target(
    client: &GitHubProtectedClient,
    target: &ReviewTarget,
    operation: &str,
) -> Result<(), CliError> {
    let (descriptor, body) = approval_request(target, operation)?;
    client.graphql_envelope(descriptor, body).await.map(|_| ())
}

fn approval_request(
    target: &ReviewTarget,
    operation: &str,
) -> Result<(GitHubRequestDescriptor, serde_json::Value), CliError> {
    if target.head_sha.trim().is_empty() {
        return Err(CliErrorKind::workflow_parse(format!(
            "cannot approve {}/pull/{} without an exact head commit",
            target.repository, target.number
        ))
        .into());
    }

    Ok((
        mutation_descriptor(operation),
        json!({
            "query": APPROVE_MUTATION,
            "variables": {
                "id": target.pull_request_id,
                "commitOID": target.head_sha,
            },
        }),
    ))
}

async fn merge_target(
    automation: &GitHubApiAutomationClient,
    target: &ReviewTarget,
    method: GitHubMergeMethod,
) -> Result<(), CliError> {
    if let Some(config) = github_project_config(&target.repository) {
        automation
            .merge_pull_request(
                &config,
                target.number,
                method,
                Some(target.head_sha.as_str()),
            )
            .await
    } else {
        Err(CliErrorKind::workflow_parse(format!(
            "invalid reviews repository '{}'",
            target.repository
        ))
        .into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reviews::{
        ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
        ReviewTargetFlags,
    };

    #[test]
    fn approval_mutation_requires_commit_oid() {
        assert!(APPROVE_MUTATION.contains("$commitOID: GitObjectID!"));
        assert!(APPROVE_MUTATION.contains("commitOID: $commitOID"));
    }

    #[test]
    fn every_approval_path_binds_the_target_head_sha() {
        let target = review_target();

        for operation in [DIRECT_APPROVAL_OPERATION, POLICY_APPROVAL_OPERATION] {
            let (descriptor, body) =
                approval_request(&target, operation).expect("valid approval target");

            assert_eq!(descriptor.operation, operation);
            assert_eq!(
                body.pointer("/variables/commitOID")
                    .and_then(serde_json::Value::as_str),
                Some(target.head_sha.as_str())
            );
            assert_eq!(
                body.pointer("/variables/id")
                    .and_then(serde_json::Value::as_str),
                Some(target.pull_request_id.as_str())
            );
        }
    }

    #[test]
    fn every_approval_path_rejects_a_blank_target_head_sha() {
        for head_sha in ["", " \t"] {
            let mut target = review_target();
            target.head_sha = head_sha.to_owned();

            for operation in [DIRECT_APPROVAL_OPERATION, POLICY_APPROVAL_OPERATION] {
                let error = approval_request(&target, operation)
                    .expect_err("approval must require an exact target head");

                assert_eq!(error.code(), "WORKFLOW_PARSE");
                assert!(error.to_string().contains("exact head commit"));
            }
        }
    }

    fn review_target() -> ReviewTarget {
        ReviewTarget {
            pull_request_id: "PR_kwDOexample".to_owned(),
            repository_id: "R_kwDOexample".to_owned(),
            repository: "example/widgets".to_owned(),
            number: 42,
            url: "https://github.com/example/widgets/pull/42".to_owned(),
            state: ReviewPullRequestState::Open,
            head_sha: "0123456789abcdef".to_owned(),
            mergeable: ReviewMergeableState::Mergeable,
            review_status: ReviewReviewStatus::ReviewRequired,
            check_status: ReviewCheckStatus::Success,
            flags: ReviewTargetFlags::default(),
            viewer_can_merge_as_admin: false,
            required_failed_check_names: Vec::new(),
            check_suite_ids: Vec::new(),
            has_conflict_markers: None,
            viewer_has_active_approval: None,
            auto_merge_enabled: None,
            approval_requirement_satisfied_after_viewer_approval: None,
        }
    }
}
