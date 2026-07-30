use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{
    TaskBoardDependencyFixResult, TaskBoardPullRequestHeadIdentity, TaskBoardPullRequestIdentity,
    valid_head_revision,
};
use crate::normalize_repository_slug;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyFixDeliveryRequest {
    pub pull_request: TaskBoardPullRequestIdentity,
    pub worktree: String,
    pub fix_result: TaskBoardDependencyFixResult,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyFixWorkingCopyEvidence {
    pub head_revision: String,
    pub tree_revision: String,
    pub contains_base_revision: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyFixRemoteHeadEvidence {
    pub head: TaskBoardPullRequestHeadIdentity,
    pub tree_revision: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskBoardDependencyFixDeliveryBlockReason {
    FixerBlocked,
    IsolatedCheckoutUnavailable,
    PullRequestTargetChanged,
    HeadRace,
    ForkAccessUnavailable,
    PermissionDenied,
    BranchUnavailable,
    PublicationFailed,
    RemoteHeadMismatch,
    ResultRecordingFailed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyFixDeliveryFailure {
    pub reason: TaskBoardDependencyFixDeliveryBlockReason,
    pub detail: String,
}

impl TaskBoardDependencyFixDeliveryFailure {
    #[must_use]
    pub fn new(
        reason: TaskBoardDependencyFixDeliveryBlockReason,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            reason,
            detail: detail.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardDependencyFixDeliveryOutcome {
    Delivered { remote_head_revision: String },
    HumanRequired(TaskBoardDependencyFixDeliveryFailure),
}

#[async_trait]
pub trait TaskBoardDependencyFixDeliveryClient: Send + Sync {
    /// Inspect the isolated fixer checkout without mutating it.
    async fn working_copy_evidence(
        &self,
        worktree: &str,
        base_head_revision: &str,
    ) -> Result<TaskBoardDependencyFixWorkingCopyEvidence, TaskBoardDependencyFixDeliveryFailure>;

    /// Load the pull request's current source repository, branch, revision, and tree.
    async fn pull_request_head(
        &self,
        repository: &str,
        pull_request_number: u64,
    ) -> Result<TaskBoardDependencyFixRemoteHeadEvidence, TaskBoardDependencyFixDeliveryFailure>;

    /// Publish only the frozen source branch, guarded by `expected_head_revision`.
    async fn publish_source_branch(
        &self,
        source_repository: &str,
        source_branch: &str,
        worktree: &str,
        expected_head_revision: &str,
    ) -> Result<(), TaskBoardDependencyFixDeliveryFailure>;

    /// Durably record the proven remote head before the workflow may resume CI waiting.
    async fn record_remote_head(
        &self,
        request: &TaskBoardDependencyFixDeliveryRequest,
        remote_head_revision: &str,
    ) -> Result<(), TaskBoardDependencyFixDeliveryFailure>;
}

/// Deliver one validated fixer result to its frozen pull request source branch.
///
/// # Errors
///
/// Rejects malformed or internally inconsistent delivery requests. Expected external delivery
/// failures are returned as explicit human-required outcomes.
pub async fn deliver_task_board_dependency_fix(
    request: &TaskBoardDependencyFixDeliveryRequest,
    client: &dyn TaskBoardDependencyFixDeliveryClient,
) -> Result<TaskBoardDependencyFixDeliveryOutcome, CliError> {
    let frozen_head = validate_delivery_request(request)?;
    if !request.fix_result.remaining_blockers.is_empty() {
        return Ok(human_required(
            TaskBoardDependencyFixDeliveryBlockReason::FixerBlocked,
            request.fix_result.remaining_blockers.join("; "),
        ));
    }
    let local = match client
        .working_copy_evidence(&request.worktree, &request.fix_result.base_head_revision)
        .await
    {
        Ok(local) => local,
        Err(failure) => {
            return Ok(TaskBoardDependencyFixDeliveryOutcome::HumanRequired(
                failure,
            ));
        }
    };
    if local.head_revision != request.fix_result.head_revision
        || !local.contains_base_revision
        || !valid_head_revision(&local.tree_revision)
    {
        return Ok(human_required(
            TaskBoardDependencyFixDeliveryBlockReason::IsolatedCheckoutUnavailable,
            "fixer checkout does not contain the reported exact-head result and its recorded base",
        ));
    }
    let before = match client
        .pull_request_head(
            &request.pull_request.repository,
            request.pull_request.number,
        )
        .await
    {
        Ok(head) => head,
        Err(failure) => {
            return Ok(TaskBoardDependencyFixDeliveryOutcome::HumanRequired(
                failure,
            ));
        }
    };
    if !same_source(&before.head, frozen_head) {
        return Ok(human_required(
            TaskBoardDependencyFixDeliveryBlockReason::PullRequestTargetChanged,
            "pull request source repository or branch changed after fixer dispatch",
        ));
    }
    if before.head.revision != frozen_head.revision {
        return Ok(human_required(
            TaskBoardDependencyFixDeliveryBlockReason::HeadRace,
            "pull request head changed after fixer dispatch",
        ));
    }
    if let Err(failure) = client
        .publish_source_branch(
            &frozen_head.repository,
            &frozen_head.branch,
            &request.worktree,
            &frozen_head.revision,
        )
        .await
    {
        return Ok(TaskBoardDependencyFixDeliveryOutcome::HumanRequired(
            failure,
        ));
    }
    Ok(verify_and_record_delivery(request, client, frozen_head, &local).await)
}

async fn verify_and_record_delivery(
    request: &TaskBoardDependencyFixDeliveryRequest,
    client: &dyn TaskBoardDependencyFixDeliveryClient,
    frozen_head: &TaskBoardPullRequestHeadIdentity,
    local: &TaskBoardDependencyFixWorkingCopyEvidence,
) -> TaskBoardDependencyFixDeliveryOutcome {
    let after = match client
        .pull_request_head(
            &request.pull_request.repository,
            request.pull_request.number,
        )
        .await
    {
        Ok(head) => head,
        Err(failure) => {
            return TaskBoardDependencyFixDeliveryOutcome::HumanRequired(failure);
        }
    };
    if !same_source(&after.head, frozen_head)
        || after.head.revision == frozen_head.revision
        || after.tree_revision != local.tree_revision
        || !valid_head_revision(&after.head.revision)
    {
        return human_required(
            TaskBoardDependencyFixDeliveryBlockReason::RemoteHeadMismatch,
            "published pull request head does not match the fixer checkout",
        );
    }
    if let Err(failure) = client
        .record_remote_head(request, &after.head.revision)
        .await
    {
        return TaskBoardDependencyFixDeliveryOutcome::HumanRequired(failure);
    }
    TaskBoardDependencyFixDeliveryOutcome::Delivered {
        remote_head_revision: after.head.revision,
    }
}

fn validate_delivery_request(
    request: &TaskBoardDependencyFixDeliveryRequest,
) -> Result<&TaskBoardPullRequestHeadIdentity, CliError> {
    let head =
        request.pull_request.head.as_ref().ok_or_else(|| {
            parse_error("dependency fix delivery has no frozen pull request source")
        })?;
    let changed = !request.fix_result.changed_paths.is_empty();
    let blocked = !request.fix_result.remaining_blockers.is_empty();
    if request.pull_request.number == 0
        || normalize_repository_slug(Some(&request.pull_request.repository)).as_deref()
            != Some(request.pull_request.repository.as_str())
        || request.worktree.trim().is_empty()
        || request.worktree.trim() != request.worktree
        || normalize_repository_slug(Some(&head.repository)).as_deref()
            != Some(head.repository.as_str())
        || head.branch.trim().is_empty()
        || head.branch.trim() != head.branch
        || !valid_head_revision(&head.revision)
        || request.fix_result.base_head_revision != head.revision
        || !valid_head_revision(&request.fix_result.head_revision)
        || (!blocked && (!changed || request.fix_result.head_revision == head.revision))
    {
        return Err(parse_error(
            "dependency fix delivery does not match its frozen pull request head",
        ));
    }
    Ok(head)
}

fn same_source(
    observed: &TaskBoardPullRequestHeadIdentity,
    frozen: &TaskBoardPullRequestHeadIdentity,
) -> bool {
    observed.repository == frozen.repository && observed.branch == frozen.branch
}

fn human_required(
    reason: TaskBoardDependencyFixDeliveryBlockReason,
    detail: impl Into<String>,
) -> TaskBoardDependencyFixDeliveryOutcome {
    TaskBoardDependencyFixDeliveryOutcome::HumanRequired(
        TaskBoardDependencyFixDeliveryFailure::new(reason, detail),
    )
}

fn parse_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(detail.into()).into()
}

#[cfg(test)]
mod tests;
