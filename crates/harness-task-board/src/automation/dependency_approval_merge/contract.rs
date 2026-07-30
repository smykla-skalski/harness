use harness_kernel::errors::{CliError, CliErrorKind};

use super::{
    TaskBoardDependencyCompletionPolicy, TaskBoardDependencyCompletionRecord,
    TaskBoardDependencyCompletionRequest, TaskBoardDependencyCompletionStatus,
};
use crate::github::{GitHubProjectConfig, PullRequestEvidence};
use crate::{TaskBoardDependencyReverificationDecision, normalize_repository_slug};

pub(super) fn record(
    request: &TaskBoardDependencyCompletionRequest,
    evidence: &PullRequestEvidence,
    status: TaskBoardDependencyCompletionStatus,
    detail: String,
) -> TaskBoardDependencyCompletionRecord {
    TaskBoardDependencyCompletionRecord {
        schema_version: super::TASK_BOARD_DEPENDENCY_COMPLETION_SCHEMA_VERSION,
        route_id: request.route_id.clone(),
        board_item_id: request.board_item_id.clone(),
        workflow_execution_id: request.workflow_execution_id.clone(),
        repository: request.repository.clone(),
        pull_request_number: request.pull_request_number,
        verified_head_revision: request.verified_head_revision.clone(),
        merge_method: request.merge_method,
        status,
        current_approvals: evidence.gates.review.current_approvals,
        required_approvals: evidence.gates.review.required_approvals,
        detail,
    }
}

pub(super) fn validate_request(
    request: &TaskBoardDependencyCompletionRequest,
    policy: &TaskBoardDependencyCompletionPolicy,
    config: &GitHubProjectConfig,
) -> Result<(), CliError> {
    let valid_scope = [
        &request.route_id,
        &request.board_item_id,
        &request.workflow_execution_id,
    ]
    .into_iter()
    .all(|value| !value.trim().is_empty() && value.trim() == value);
    let reverification_matches = request.reverification.decision
        == TaskBoardDependencyReverificationDecision::GreenLight
        && request.reverification.repair_instructions.is_empty()
        && request.reverification.repository == request.repository
        && request.reverification.pull_request_number == request.pull_request_number
        && request.reverification.exact_head_revision == request.verified_head_revision;
    if !valid_scope
        || normalize_repository_slug(Some(&request.repository)).as_deref()
            != Some(request.repository.as_str())
        || config.repository_slug().to_ascii_lowercase() != request.repository
        || request.pull_request_number == 0
        || !super::valid_head_revision(&request.verified_head_revision)
        || !reverification_matches
        || !policy.allowed_merge_methods.contains(&request.merge_method)
    {
        return Err(CliErrorKind::workflow_parse(
            "dependency completion request is not authorized for its verified head and merge method",
        )
        .into());
    }
    Ok(())
}
