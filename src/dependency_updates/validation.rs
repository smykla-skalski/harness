use crate::errors::{CliError, CliErrorKind};

use super::{
    DependencyUpdateTarget, DependencyUpdatesApproveRequest, DependencyUpdatesAutoRequest,
    DependencyUpdatesLabelRequest, DependencyUpdatesMergeRequest, DependencyUpdatesQueryRequest,
    DependencyUpdatesRefreshRequest, DependencyUpdatesRepositoryCatalogRequest,
    DependencyUpdatesRerunChecksRequest,
};

impl DependencyUpdatesQueryRequest {
    /// Validate the query request.
    ///
    /// # Errors
    /// Returns `CliError` when the request has no author filters or no
    /// organization/repository scope.
    pub fn validate(&self) -> Result<(), CliError> {
        if self.normalized_authors().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "dependency-updates query requires at least one author",
            )
            .into());
        }
        if self.normalized_organizations().is_empty() && self.normalized_repositories().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "dependency-updates query requires at least one organization or repository",
            )
            .into());
        }
        Ok(())
    }
}

impl DependencyUpdatesRepositoryCatalogRequest {
    /// Validate the repository catalog request.
    ///
    /// # Errors
    /// Returns `CliError` when the organization login is empty or contains a
    /// repository path separator.
    pub fn validate(&self) -> Result<(), CliError> {
        let organization = self.organization.trim();
        if organization.is_empty() || organization.contains('/') {
            return Err(CliErrorKind::workflow_parse(
                "dependency-updates repository catalog requires a valid organization login",
            )
            .into());
        }
        Ok(())
    }
}

impl DependencyUpdatesApproveRequest {
    /// Validate the approve request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "approve")
    }
}

impl DependencyUpdatesMergeRequest {
    /// Validate the merge request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "merge")
    }
}

impl DependencyUpdatesRerunChecksRequest {
    /// Validate the rerun-checks request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "rerun checks")
    }
}

impl DependencyUpdatesLabelRequest {
    /// Validate the label request.
    ///
    /// # Errors
    /// Returns `CliError` when no targets are provided or the label is empty.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "label")?;
        if self.label.trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "dependency-updates label request requires a non-empty label",
            )
            .into());
        }
        Ok(())
    }
}

impl DependencyUpdatesAutoRequest {
    /// Validate the automatic dependency update request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "auto mode")
    }
}

impl DependencyUpdatesRefreshRequest {
    /// Validate the refresh request.
    ///
    /// # Errors
    /// Returns `CliError` when no dependency update targets are provided.
    pub fn validate(&self) -> Result<(), CliError> {
        ensure_targets(&self.targets, "refresh")
    }
}

fn ensure_targets(targets: &[DependencyUpdateTarget], action: &str) -> Result<(), CliError> {
    if targets.is_empty() {
        return Err(CliErrorKind::workflow_parse(format!(
            "dependency-updates {action} request requires at least one target"
        ))
        .into());
    }
    Ok(())
}
