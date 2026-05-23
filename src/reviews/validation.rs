use crate::errors::{CliError, CliErrorKind};

use super::{
    ReviewTarget, ReviewsActionPreviewRequest, ReviewsApproveRequest,
    ReviewsAutoRequest, ReviewsBodyRequest, ReviewsBodyUpdateRequest,
    ReviewsCommentRequest, ReviewsLabelRequest, ReviewsMergeRequest,
    ReviewsQueryRequest, ReviewsRefreshRequest,
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
        ensure_targets(&self.targets, "refresh")
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
