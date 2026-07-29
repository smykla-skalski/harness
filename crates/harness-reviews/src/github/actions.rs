use std::slice;

use serde_json::json;

use harness_github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_task_board::github::{
    ActionGateBlock, ActionGateDecision, ActionGateRequirement, GitHubApiAutomationClient,
    GitHubAutomationClient, GitHubMergeMethod, GitHubPullRequestEvidenceSource,
    PullRequestEvidenceSource, PullRequestIdentity, verify_action_gates,
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
    pub async fn fetch_viewer_login(&self) -> Option<String> {
        self.client.viewer_login().await.ok()
    }

    /// # Errors
    ///
    /// Never returns `Err`; each target's outcome is captured in its own
    /// [`ReviewActionResult`] instead.
    pub async fn approve(
        &self,
        request: &ReviewsApproveRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let source = GitHubPullRequestEvidenceSource::new(&self.client);
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result =
                match verify_target_gate(&source, target, ActionGateRequirement::for_approval())
                    .await
                {
                    Ok(()) => approve_target(&self.client, target, DIRECT_APPROVAL_OPERATION).await,
                    Err(error) => Err(error),
                };
            results.push(action_result(target, ReviewActionKind::Approve, result));
        }
        Ok(results)
    }

    /// # Errors
    ///
    /// Returns an error if the target has no exact head commit, a fresh read
    /// blocks the approval, or the GitHub GraphQL mutation fails.
    pub async fn policy_approve(&self, target: &ReviewTarget) -> Result<(), CliError> {
        let source = GitHubPullRequestEvidenceSource::new(&self.client);
        verify_target_gate(&source, target, ActionGateRequirement::for_approval()).await?;
        approve_target(&self.client, target, POLICY_APPROVAL_OPERATION).await
    }

    /// # Errors
    ///
    /// Never returns `Err`; each target's outcome is captured in its own
    /// [`ReviewActionResult`] instead.
    pub async fn comment(
        &self,
        request: &ReviewsCommentRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let source = GitHubPullRequestEvidenceSource::new(&self.client);
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result =
                match verify_target_gate(&source, target, ActionGateRequirement::for_comment())
                    .await
                {
                    Ok(()) => self
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
                        .map(|response| response.body),
                    Err(error) => Err(error),
                };
            results.push(comment_action_result(target, result));
        }
        Ok(results)
    }

    /// # Errors
    ///
    /// Returns an error if the GitHub GraphQL mutation fails.
    pub async fn add_file_comment(
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

    /// # Errors
    ///
    /// Never returns `Err`; each target's outcome is captured in its own
    /// [`ReviewActionResult`] instead.
    pub async fn merge(
        &self,
        request: &ReviewsMergeRequest,
    ) -> Result<Vec<ReviewActionResult>, CliError> {
        let source = GitHubPullRequestEvidenceSource::new(&self.client);
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result =
                match verify_target_gate(&source, target, ActionGateRequirement::for_merge()).await
                {
                    Ok(()) => merge_target(&self.automation, target, request.method).await,
                    Err(error) => Err(error),
                };
            results.push(action_result(target, ReviewActionKind::Merge, result));
        }
        Ok(results)
    }

    /// # Errors
    ///
    /// Returns an error if the repository has no automation config, a fresh
    /// read blocks the merge, or the GitHub merge mutation fails.
    pub async fn policy_merge(
        &self,
        target: &ReviewTarget,
        method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        let source = GitHubPullRequestEvidenceSource::new(&self.client);
        verify_target_gate(&source, target, ActionGateRequirement::for_merge()).await?;
        merge_target(&self.automation, target, method).await
    }

    /// Merge without the fresh-evidence gate, for a caller that runs the gate
    /// itself. The durable merge ledger verifies the gates immediately before
    /// issuing this call, so re-checking here would only duplicate the read.
    ///
    /// # Errors
    ///
    /// Returns an error if the repository has no automation config or the
    /// GitHub merge mutation fails.
    pub async fn merge_verified(
        &self,
        target: &ReviewTarget,
        method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        merge_target(&self.automation, target, method).await
    }

    /// # Errors
    ///
    /// Never returns `Err`; each target's outcome is captured in its own
    /// [`ReviewActionResult`] instead.
    pub async fn rerun_checks(
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

    /// # Errors
    ///
    /// Never returns `Err`; each target's outcome is captured in its own
    /// [`ReviewActionResult`] instead.
    pub async fn add_label(
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

    /// # Errors
    ///
    /// Never returns `Err`; each target's outcome is captured in its own
    /// [`ReviewActionResult`] instead.
    pub async fn request_review(
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

/// Refuse an action unless a fresh read still clears its gates on the head the
/// target was captured on. Every approve, merge, and comment path runs this
/// immediately before its mutation, so a decision made on a stale list never
/// acts once the head, gates, or permissions have moved.
async fn verify_target_gate(
    source: &dyn PullRequestEvidenceSource,
    target: &ReviewTarget,
    requirement: ActionGateRequirement,
) -> Result<(), CliError> {
    if target.head_sha.trim().is_empty() {
        return Err(CliErrorKind::workflow_parse(format!(
            "cannot act on {}/pull/{} without an exact head commit",
            target.repository, target.number
        ))
        .into());
    }
    let identity = PullRequestIdentity::from_slug(target.repository.clone(), target.number)
        .with_url(Some(target.url.clone()));
    match verify_action_gates(source, &identity, &target.head_sha, requirement).await? {
        ActionGateDecision::Proceed(_) => Ok(()),
        ActionGateDecision::Blocked(blocks) => Err(gate_refusal_error(target, &blocks)),
    }
}

fn gate_refusal_error(target: &ReviewTarget, blocks: &[ActionGateBlock]) -> CliError {
    let reasons = blocks
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("; ");
    CliErrorKind::workflow_io(format!(
        "refused {}/pull/{}: {reasons}",
        target.repository, target.number
    ))
    .into()
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
    use crate::{
        ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
        ReviewTargetFlags,
    };
    use harness_task_board::github::{
        CheckGate, CheckState, InMemoryPullRequestEvidenceSource, Mergeability,
        PullRequestEvidence, PullRequestLifecycle, PullRequestMergeGates, ReviewDecision,
        ReviewGate,
    };

    const HEAD: &str = "0123456789abcdef";

    #[tokio::test]
    async fn an_approval_proceeds_when_the_head_still_matches() {
        let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
            HEAD,
            PullRequestLifecycle::Open,
            false,
            minimal_gates(),
        ));

        verify_target_gate(
            &source,
            &review_target(),
            ActionGateRequirement::for_approval(),
        )
        .await
        .expect("open pull request on the verified head clears the approval gate");
    }

    #[tokio::test]
    async fn an_approval_is_refused_when_the_head_moved() {
        let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
            "feeddeadbeef",
            PullRequestLifecycle::Open,
            false,
            minimal_gates(),
        ));

        let error = verify_target_gate(
            &source,
            &review_target(),
            ActionGateRequirement::for_approval(),
        )
        .await
        .expect_err("a moved head must refuse the approval");
        assert!(error.to_string().contains("head moved"));
    }

    #[tokio::test]
    async fn an_action_is_refused_when_the_pull_request_is_missing() {
        let source = InMemoryPullRequestEvidenceSource::new();

        let error = verify_target_gate(
            &source,
            &review_target(),
            ActionGateRequirement::for_approval(),
        )
        .await
        .expect_err("a vanished pull request must refuse the action");
        assert!(error.to_string().contains("no longer present"));
    }

    #[tokio::test]
    async fn an_action_is_refused_without_an_exact_head() {
        let source = InMemoryPullRequestEvidenceSource::new();
        let mut target = review_target();
        target.head_sha = "  ".to_owned();

        let error = verify_target_gate(&source, &target, ActionGateRequirement::for_comment())
            .await
            .expect_err("a blank head must refuse the action before any read");
        assert_eq!(error.code(), "WORKFLOW_PARSE");
    }

    #[tokio::test]
    async fn a_merge_is_refused_when_the_gates_are_not_green() {
        let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
            HEAD,
            PullRequestLifecycle::Open,
            false,
            minimal_gates(),
        ));

        let error = verify_target_gate(
            &source,
            &review_target(),
            ActionGateRequirement::for_merge(),
        )
        .await
        .expect_err("an unmergeable, unapproved pull request must refuse the merge");
        assert!(error.to_string().contains("refused"));
    }

    #[tokio::test]
    async fn a_merge_proceeds_when_every_gate_is_green() {
        let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
            HEAD,
            PullRequestLifecycle::Open,
            false,
            green_gates(),
        ));

        verify_target_gate(
            &source,
            &review_target(),
            ActionGateRequirement::for_merge(),
        )
        .await
        .expect("a green pull request clears the merge gate");
    }

    #[tokio::test]
    async fn a_comment_proceeds_on_a_draft_as_long_as_the_head_holds() {
        let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
            HEAD,
            PullRequestLifecycle::Open,
            true,
            minimal_gates(),
        ));

        verify_target_gate(
            &source,
            &review_target(),
            ActionGateRequirement::for_comment(),
        )
        .await
        .expect("a comment does not require a non-draft, mergeable pull request");
    }

    #[tokio::test]
    async fn a_comment_is_refused_when_the_head_moved() {
        let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
            "feeddeadbeef",
            PullRequestLifecycle::Open,
            false,
            minimal_gates(),
        ));

        verify_target_gate(
            &source,
            &review_target(),
            ActionGateRequirement::for_comment(),
        )
        .await
        .expect_err("a comment must not post onto a moved head");
    }

    fn evidence(
        head: &str,
        lifecycle: PullRequestLifecycle,
        is_draft: bool,
        gates: PullRequestMergeGates,
    ) -> PullRequestEvidence {
        PullRequestEvidence {
            identity: PullRequestIdentity::from_slug("example/widgets", 42),
            head_revision: head.to_owned(),
            author: None,
            lifecycle,
            is_draft,
            gates,
            observed_at: "2026-07-29T00:00:00Z".to_owned(),
        }
    }

    fn minimal_gates() -> PullRequestMergeGates {
        PullRequestMergeGates {
            mergeability: Mergeability::Unknown,
            viewer_can_update: false,
            viewer_can_merge_as_admin: false,
            checks: Vec::new(),
            required_check_names: Vec::new(),
            review: ReviewGate {
                decision: ReviewDecision::ReviewRequired,
                current_approvals: 0,
                required_approvals: 1,
            },
        }
    }

    fn green_gates() -> PullRequestMergeGates {
        PullRequestMergeGates {
            mergeability: Mergeability::Mergeable,
            viewer_can_update: true,
            viewer_can_merge_as_admin: false,
            checks: vec![CheckGate {
                name: "build".to_owned(),
                state: CheckState::Success,
                details_url: None,
            }],
            required_check_names: vec!["build".to_owned()],
            review: ReviewGate {
                decision: ReviewDecision::Approved,
                current_approvals: 1,
                required_approvals: 1,
            },
        }
    }

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
