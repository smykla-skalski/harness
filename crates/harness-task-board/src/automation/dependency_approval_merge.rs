use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use super::{TaskBoardDependencyReverificationResult, valid_head_revision};
use crate::github::{
    ActionAdmission, ActionGateBlock, ActionGateDecision, ActionGateRequirement, ActionOutcome,
    GitHubAutomationClient, GitHubMergeMethod, GitHubProjectConfig, PullRequestAction,
    PullRequestActionFailureClass, PullRequestActionKind, PullRequestActionStore,
    PullRequestEvidence, PullRequestEvidenceRead, PullRequestIdentity, PullRequestLifecycle,
    begin_action, evaluate_action_gates, finish_action, reconcile_action,
};
mod approval;
mod contract;

use approval::{ApprovalPhase, satisfy_approval_requirement};
use contract::{record, validate_request};

pub const TASK_BOARD_DEPENDENCY_COMPLETION_SCHEMA_VERSION: u32 = 1;
static DEPENDENCY_COMPLETION_LOCK: Mutex<()> = Mutex::const_new(());

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyCompletionRequest {
    pub route_id: String,
    pub board_item_id: String,
    pub workflow_execution_id: String,
    pub repository: String,
    pub pull_request_number: u64,
    pub verified_head_revision: String,
    pub reverification: TaskBoardDependencyReverificationResult,
    pub merge_method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyCompletionPolicy {
    pub automated_approval_allowed: bool,
    pub allowed_merge_methods: Vec<GitHubMergeMethod>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyCompletionStatus {
    ApprovalSubmitted,
    HumanRequired,
    ReverificationRequired,
    WaitingForGates,
    Merged,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyCompletionRecord {
    pub schema_version: u32,
    pub route_id: String,
    pub board_item_id: String,
    pub workflow_execution_id: String,
    pub repository: String,
    pub pull_request_number: u64,
    pub verified_head_revision: String,
    pub merge_method: GitHubMergeMethod,
    pub status: TaskBoardDependencyCompletionStatus,
    pub current_approvals: u32,
    pub required_approvals: u32,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardDependencyCompletionOutcome {
    Merged {
        record: TaskBoardDependencyCompletionRecord,
        created: bool,
    },
    Paused(TaskBoardDependencyCompletionRecord),
}

#[async_trait]
pub trait TaskBoardDependencyCompletionSink: Send + Sync {
    /// Persist the exact-head completion state into its bound task ticket.
    ///
    /// Replaying an identical record must be idempotent. Implementations must reject a record for
    /// another workflow execution or a conflicting terminal history.
    ///
    /// # Errors
    /// Returns a persistence error before the outcome is reported.
    async fn record(&self, record: &TaskBoardDependencyCompletionRecord) -> Result<(), CliError>;
}

/// Approve when policy and account evidence permit it, then merge the same verified head.
///
/// Every mutation is preceded by a no-cache evidence read. Both approval and merge intents are
/// recorded before GitHub sees them, so a retry reconciles or adopts the prior effect instead of
/// issuing it twice.
///
/// # Errors
/// Returns validation, storage, evidence-read, or GitHub mutation errors.
pub async fn complete_task_board_dependency_pull_request(
    request: &TaskBoardDependencyCompletionRequest,
    policy: &TaskBoardDependencyCompletionPolicy,
    config: &GitHubProjectConfig,
    client: &dyn GitHubAutomationClient,
    actions: &dyn PullRequestActionStore,
    sink: &dyn TaskBoardDependencyCompletionSink,
) -> Result<TaskBoardDependencyCompletionOutcome, CliError> {
    validate_request(request, policy, config)?;
    let _completion_guard = DEPENDENCY_COMPLETION_LOCK.lock().await;
    let identity =
        PullRequestIdentity::from_slug(request.repository.clone(), request.pull_request_number);
    let evidence = read_evidence(client, config, request.pull_request_number).await?;
    if evidence.head_revision != request.verified_head_revision {
        return pause(
            request,
            sink,
            &evidence,
            TaskBoardDependencyCompletionStatus::ReverificationRequired,
            format!(
                "pull request head moved from verified {} to {}",
                request.verified_head_revision, evidence.head_revision
            ),
        )
        .await;
    }
    if evidence.lifecycle == PullRequestLifecycle::Merged {
        return persist_merged(request, sink, &evidence, false).await;
    }

    match satisfy_approval_requirement(request, policy, config, client, actions, sink, evidence)
        .await?
    {
        ApprovalPhase::Continue => {}
        ApprovalPhase::Complete(outcome) => return Ok(outcome),
    }

    merge_verified_head(MergeContext {
        request,
        config,
        client,
        actions,
        sink,
        identity: &identity,
    })
    .await
}

#[derive(Clone, Copy)]
struct MergeContext<'a> {
    request: &'a TaskBoardDependencyCompletionRequest,
    config: &'a GitHubProjectConfig,
    client: &'a dyn GitHubAutomationClient,
    actions: &'a dyn PullRequestActionStore,
    sink: &'a dyn TaskBoardDependencyCompletionSink,
    identity: &'a PullRequestIdentity,
}

async fn merge_verified_head(
    context: MergeContext<'_>,
) -> Result<TaskBoardDependencyCompletionOutcome, CliError> {
    let action = action(context.request, PullRequestActionKind::Merge);
    if let Some(outcome) = admit_merge(context, &action).await? {
        return Ok(outcome);
    }
    let evidence = read_evidence(
        context.client,
        context.config,
        context.request.pull_request_number,
    )
    .await?;
    let read = PullRequestEvidenceRead::found(evidence.clone());
    if let ActionGateDecision::Blocked(blocks) = evaluate_action_gates(
        &read,
        &context.request.verified_head_revision,
        ActionGateRequirement::for_merge(),
    ) {
        finish_blocked(context.actions, &action.id, &blocks).await?;
        return pause_for_blocks(context.request, context.sink, &evidence, blocks).await;
    }
    issue_merge(context, &action, &evidence).await
}

async fn admit_merge(
    context: MergeContext<'_>,
    action: &PullRequestAction,
) -> Result<Option<TaskBoardDependencyCompletionOutcome>, CliError> {
    match begin_action(context.actions, action.clone()).await? {
        ActionAdmission::AlreadyApplied => {
            let evidence = read_evidence(
                context.client,
                context.config,
                context.request.pull_request_number,
            )
            .await?;
            persist_merged(context.request, context.sink, &evidence, false)
                .await
                .map(Some)
        }
        ActionAdmission::Abandoned => {
            Err(CliErrorKind::workflow_io("dependency merge previously failed permanently").into())
        }
        ActionAdmission::NeedsReconcile => reconcile_merge(context, action).await,
        ActionAdmission::Proceed => Ok(None),
    }
}

async fn reconcile_merge(
    context: MergeContext<'_>,
    action: &PullRequestAction,
) -> Result<Option<TaskBoardDependencyCompletionOutcome>, CliError> {
    let observed = read_evidence(
        context.client,
        context.config,
        context.request.pull_request_number,
    )
    .await?;
    let applied = observed.lifecycle == PullRequestLifecycle::Merged
        && observed.head_revision == context.request.verified_head_revision;
    if reconcile_action(context.actions, action.clone(), applied).await?
        != ActionAdmission::AlreadyApplied
    {
        return Ok(None);
    }
    persist_merged(context.request, context.sink, &observed, false)
        .await
        .map(Some)
}

async fn issue_merge(
    context: MergeContext<'_>,
    action: &PullRequestAction,
    evidence: &PullRequestEvidence,
) -> Result<TaskBoardDependencyCompletionOutcome, CliError> {
    match context
        .client
        .merge_pull_request(
            context.config,
            context.identity.number,
            context.request.merge_method,
            Some(&context.request.verified_head_revision),
        )
        .await
    {
        Ok(()) => {
            finish_action(context.actions, &action.id, ActionOutcome::Succeeded).await?;
            persist_merged(context.request, context.sink, evidence, true).await
        }
        Err(error) => {
            finish_action(
                context.actions,
                &action.id,
                ActionOutcome::Uncertain {
                    detail: error.to_string(),
                },
            )
            .await?;
            Err(error)
        }
    }
}

async fn read_evidence(
    client: &dyn GitHubAutomationClient,
    config: &GitHubProjectConfig,
    number: u64,
) -> Result<PullRequestEvidence, CliError> {
    match client.read_pull_request_evidence(config, number).await? {
        PullRequestEvidenceRead::Found(evidence) => Ok(*evidence),
        PullRequestEvidenceRead::Missing { .. } => {
            Err(CliErrorKind::workflow_io("dependency pull request is no longer present").into())
        }
    }
}

fn account_can_approve(evidence: &PullRequestEvidence) -> bool {
    let Some(viewer) = evidence.viewer_login.as_deref() else {
        return false;
    };
    evidence.author.as_deref() != Some(viewer)
        && (evidence.gates.viewer_can_update || evidence.gates.viewer_can_merge_as_admin)
}

fn unmet_approval_requirement(evidence: &PullRequestEvidence) -> String {
    let review = &evidence.gates.review;
    let missing = review
        .required_approvals
        .saturating_sub(review.current_approvals);
    if review.changes_requested() {
        return format!(
            "requested changes must be resolved before merge ({}/{})",
            review.current_approvals, review.required_approvals
        );
    }
    format!(
        "{missing} additional human approval(s) required ({}/{})",
        review.current_approvals, review.required_approvals
    )
}

fn action(
    request: &TaskBoardDependencyCompletionRequest,
    kind: PullRequestActionKind,
) -> PullRequestAction {
    let label = match kind {
        PullRequestActionKind::Approve => "approve",
        PullRequestActionKind::Merge => "merge",
        PullRequestActionKind::Comment => "comment",
    };
    PullRequestAction {
        id: format!(
            "{}:dependency-{label}:{}",
            request.route_id, request.verified_head_revision
        ),
        kind,
        identity: PullRequestIdentity::from_slug(
            request.repository.clone(),
            request.pull_request_number,
        ),
        head_revision: request.verified_head_revision.clone(),
    }
}

async fn finish_blocked(
    actions: &dyn PullRequestActionStore,
    id: &str,
    blocks: &[ActionGateBlock],
) -> Result<(), CliError> {
    finish_action(
        actions,
        id,
        ActionOutcome::Failed {
            class: PullRequestActionFailureClass::Transient,
            detail: blocks
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join("; "),
        },
    )
    .await
}

async fn pause_for_blocks(
    request: &TaskBoardDependencyCompletionRequest,
    sink: &dyn TaskBoardDependencyCompletionSink,
    evidence: &PullRequestEvidence,
    blocks: Vec<ActionGateBlock>,
) -> Result<TaskBoardDependencyCompletionOutcome, CliError> {
    let status = if blocks
        .iter()
        .any(|block| matches!(block, ActionGateBlock::HeadMoved { .. }))
    {
        TaskBoardDependencyCompletionStatus::ReverificationRequired
    } else if blocks.iter().any(block_needs_human) {
        TaskBoardDependencyCompletionStatus::HumanRequired
    } else {
        TaskBoardDependencyCompletionStatus::WaitingForGates
    };
    pause(
        request,
        sink,
        evidence,
        status,
        blocks
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("; "),
    )
    .await
}

fn block_needs_human(block: &ActionGateBlock) -> bool {
    matches!(
        block,
        ActionGateBlock::PullRequestMissing
            | ActionGateBlock::NotOpen(_)
            | ActionGateBlock::Draft
            | ActionGateBlock::Conflicts
            | ActionGateBlock::ApprovalsMissing { .. }
            | ActionGateBlock::WritePermissionMissing
    )
}

async fn pause(
    request: &TaskBoardDependencyCompletionRequest,
    sink: &dyn TaskBoardDependencyCompletionSink,
    evidence: &PullRequestEvidence,
    status: TaskBoardDependencyCompletionStatus,
    detail: String,
) -> Result<TaskBoardDependencyCompletionOutcome, CliError> {
    let record = record(request, evidence, status, detail);
    sink.record(&record).await?;
    Ok(TaskBoardDependencyCompletionOutcome::Paused(record))
}

async fn persist_merged(
    request: &TaskBoardDependencyCompletionRequest,
    sink: &dyn TaskBoardDependencyCompletionSink,
    evidence: &PullRequestEvidence,
    created: bool,
) -> Result<TaskBoardDependencyCompletionOutcome, CliError> {
    let record = record(
        request,
        evidence,
        TaskBoardDependencyCompletionStatus::Merged,
        format!(
            "merged verified head {} using {:?}",
            request.verified_head_revision, request.merge_method
        ),
    );
    sink.record(&record).await?;
    Ok(TaskBoardDependencyCompletionOutcome::Merged { record, created })
}

#[cfg(test)]
mod tests;
