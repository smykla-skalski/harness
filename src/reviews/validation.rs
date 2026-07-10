use crate::errors::{CliError, CliErrorKind};
use crate::reviews::backports::BackportDetector;

use super::{
    ReviewTarget, ReviewsActionPreviewRequest, ReviewsApproveRequest, ReviewsAutoRequest,
    ReviewsBodyRequest, ReviewsBodyUpdateRequest, ReviewsCommentRequest, ReviewsLabelRequest,
    ReviewsMergeRequest, ReviewsPolicyHistoryRequest, ReviewsPolicyPreviewRequest,
    ReviewsPolicyRunStartRequest, ReviewsPolicyStatusRequest, ReviewsPolicySubject,
    ReviewsPullRequestResolveRequest, ReviewsQueryRequest, ReviewsRefreshRequest,
    ReviewsRepositoryCatalogRequest, ReviewsRequestReviewRequest, ReviewsRerunChecksRequest,
};

impl ReviewsQueryRequest {
    /// Validate the query request.
    ///
    /// # Errors
    /// Returns `CliError` when the request has no organization/repository
    /// scope. Authors are optional - an empty list fetches every open PR in
    /// the configured scopes.
    pub fn validate(&self) -> Result<(), CliError> {
        if self.normalized_organizations().is_empty() && self.normalized_repositories().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "reviews query requires at least one organization or repository",
            )
            .into());
        }
        BackportDetector::validate_patterns(&self.normalized_backport_patterns())?;
        Ok(())
    }
}

impl ReviewsRepositoryCatalogRequest {
    /// Validate the repository catalog request.
    ///
    /// # Errors
    /// Returns `CliError` when the organization login is empty or contains a
    /// repository path separator.
    pub fn validate(&self) -> Result<(), CliError> {
        let organization = self.organization.trim();
        if organization.is_empty() || organization.contains('/') {
            return Err(CliErrorKind::workflow_parse(
                "reviews repository catalog requires a valid organization login",
            )
            .into());
        }
        Ok(())
    }
}

impl ReviewsPullRequestResolveRequest {
    /// Validate the focused pull request reference resolve request.
    ///
    /// # Errors
    /// Returns `CliError` when no valid `owner/repo#number` references are
    /// provided or a backport pattern cannot be compiled.
    pub fn validate(&self) -> Result<(), CliError> {
        if self.normalized_references().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "reviews pull request resolve requires at least one valid repository and number",
            )
            .into());
        }
        BackportDetector::validate_patterns(&self.normalized_backport_patterns())?;
        Ok(())
    }
}

impl ReviewsApproveRequest {
    /// Validate the approve request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "approve")
    }
}

impl ReviewsMergeRequest {
    /// Validate the merge request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "merge")
    }
}

impl ReviewsRerunChecksRequest {
    /// Validate the rerun-checks request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "rerun checks")
    }
}

impl ReviewsLabelRequest {
    /// Validate the label request.
    ///
    /// # Errors
    /// Returns `CliError` when no targets are provided or the label is empty.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "label")?;
        if self.label.trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "reviews label request requires a non-empty label",
            )
            .into());
        }
        Ok(())
    }
}

impl ReviewsBodyRequest {
    /// Validate the pull request body fetch request.
    ///
    /// # Errors
    /// Returns `CliError` when the pull request id is empty.
    pub fn validate(&self) -> Result<(), CliError> {
        if self.normalized_pull_request_id().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "reviews body request requires a pull request id",
            )
            .into());
        }
        Ok(())
    }
}

impl ReviewsBodyUpdateRequest {
    /// Validate the pull request body update request.
    ///
    /// # Errors
    /// Returns `CliError` when the pull request id is empty, the expected
    /// prior-body hash is not a 64-character lowercase hex digest, or the new
    /// body exceeds `MAX_BODY_BYTES`.
    pub fn validate(&self) -> Result<(), CliError> {
        if self.normalized_pull_request_id().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "reviews body update request requires a pull request id",
            )
            .into());
        }
        let hash = self.normalized_expected_prior_body_sha256();
        if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(CliErrorKind::workflow_parse(
                "reviews body update request requires a 64-character hex SHA-256",
            )
            .into());
        }
        if self.new_body.len() > Self::MAX_BODY_BYTES {
            return Err(CliErrorKind::workflow_parse(format!(
                "reviews body update exceeds {} byte limit",
                Self::MAX_BODY_BYTES
            ))
            .into());
        }
        Ok(())
    }
}

impl ReviewsAutoRequest {
    /// Validate the automatic dependency update request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "auto mode")
    }
}

impl ReviewsCommentRequest {
    /// Validate the comment request.
    ///
    /// # Errors
    /// Returns `CliError` when no targets are provided or the body is empty.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "comment")?;
        if self.body.trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "reviews comment request requires a non-empty body",
            )
            .into());
        }
        Ok(())
    }
}

impl ReviewsRequestReviewRequest {
    /// Validate the request-review request.
    ///
    /// # Errors
    /// Returns `CliError` when no targets are provided or the reviewer
    /// login is empty after trimming.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "request review")?;
        if self.reviewer_login.trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "reviews request-review request requires a non-empty reviewer login",
            )
            .into());
        }
        Ok(())
    }
}

impl ReviewsActionPreviewRequest {
    /// Validate the action preview request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "action preview")
    }
}

impl ReviewsRefreshRequest {
    /// Validate the refresh request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "refresh")?;
        BackportDetector::validate_patterns(&self.normalized_backport_patterns())
    }
}

impl ReviewsPolicyPreviewRequest {
    /// Validate the policy preview request.
    ///
    /// # Errors
    /// Returns `CliError` when the workflow id is blank or the target lacks a
    /// valid repository / pull request number pair.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_non_blank_workflow_id(&self.normalized_workflow_id())?;
        ensure_policy_target(&self.target)
    }
}

impl ReviewsPolicyRunStartRequest {
    /// Validate the policy run start request.
    ///
    /// # Errors
    /// Returns `CliError` when the workflow id is blank or the target lacks a
    /// valid repository / pull request number pair.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_non_blank_workflow_id(&self.normalized_workflow_id())?;
        ensure_policy_target(&self.target)
    }
}

impl ReviewsPolicyStatusRequest {
    /// Validate the policy status request.
    ///
    /// # Errors
    /// Returns `CliError` when the workflow id is blank or the subject lacks a
    /// valid repository / pull request number pair.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_non_blank_workflow_id(&self.normalized_workflow_id())?;
        ensure_policy_subject(&self.subject)
    }
}

impl ReviewsPolicyHistoryRequest {
    /// Validate the policy history request.
    ///
    /// # Errors
    /// Returns `CliError` when the workflow id is blank or the subject lacks a
    /// valid repository / pull request number pair.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_non_blank_workflow_id(&self.normalized_workflow_id())?;
        ensure_policy_subject(&self.subject)
    }
}

fn ensure_targets(targets: &[ReviewTarget], action: &str) -> Result<(), CliError> {
    if targets.is_empty() {
        return Err(CliErrorKind::workflow_parse(format!(
            "reviews {action} request requires at least one target"
        ))
        .into());
    }
    Ok(())
}

fn ensure_non_blank_workflow_id(workflow_id: &str) -> Result<(), CliError> {
    if workflow_id.trim().is_empty() {
        return Err(
            CliErrorKind::workflow_parse("reviews policy request requires a workflow id").into(),
        );
    }
    Ok(())
}

fn ensure_policy_target(target: &ReviewTarget) -> Result<(), CliError> {
    ensure_policy_subject(&ReviewsPolicySubject::from_target(target))
}

fn ensure_policy_subject(subject: &ReviewsPolicySubject) -> Result<(), CliError> {
    if subject.repository.trim().is_empty() || subject.pull_request_number == 0 {
        return Err(CliErrorKind::workflow_parse(
            "reviews policy request requires a valid repository and pull request number",
        )
        .into());
    }
    Ok(())
}
