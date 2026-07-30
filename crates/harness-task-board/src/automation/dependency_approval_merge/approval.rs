use harness_kernel::errors::CliError;

use super::{
    TaskBoardDependencyCompletionOutcome, TaskBoardDependencyCompletionPolicy,
    TaskBoardDependencyCompletionRequest, TaskBoardDependencyCompletionSink,
    TaskBoardDependencyCompletionStatus, account_can_approve, action, finish_blocked, pause,
    pause_for_blocks, read_evidence, record, unmet_approval_requirement,
};
use crate::github::{
    ActionAdmission, ActionGateBlock, ActionGateDecision, ActionGateRequirement, ActionOutcome,
    GitHubAutomationClient, GitHubProjectConfig, PullRequestActionKind, PullRequestActionStore,
    PullRequestEvidence, PullRequestEvidenceRead, begin_action, evaluate_action_gates,
    finish_action, reconcile_action,
};

pub(super) enum ApprovalPhase {
    Continue,
    Complete(TaskBoardDependencyCompletionOutcome),
}

pub(super) async fn satisfy_approval_requirement(
    request: &TaskBoardDependencyCompletionRequest,
    policy: &TaskBoardDependencyCompletionPolicy,
    config: &GitHubProjectConfig,
    client: &dyn GitHubAutomationClient,
    actions: &dyn PullRequestActionStore,
    sink: &dyn TaskBoardDependencyCompletionSink,
    mut evidence: PullRequestEvidence,
) -> Result<ApprovalPhase, CliError> {
    if evidence.gates.review.is_satisfied() {
        return Ok(ApprovalPhase::Continue);
    }
    if evidence.gates.review.changes_requested() {
        return complete_pause(
            request,
            sink,
            &evidence,
            TaskBoardDependencyCompletionStatus::HumanRequired,
            unmet_approval_requirement(&evidence),
        )
        .await;
    }

    let approval = submit_approval(request, policy, config, client, actions, &evidence).await?;
    let approval_recorded = match approval {
        ApprovalProgress::Submitted => {
            let record = record(
                request,
                &evidence,
                TaskBoardDependencyCompletionStatus::ApprovalSubmitted,
                format!(
                    "automated approval submitted for verified head {}",
                    request.verified_head_revision
                ),
            );
            sink.record(&record).await?;
            true
        }
        ApprovalProgress::AlreadyApplied => true,
        ApprovalProgress::Paused(detail) => {
            return complete_pause(
                request,
                sink,
                &evidence,
                TaskBoardDependencyCompletionStatus::HumanRequired,
                detail,
            )
            .await;
        }
        ApprovalProgress::Blocked(blocks) => {
            let outcome = pause_for_blocks(request, sink, &evidence, blocks).await?;
            return Ok(ApprovalPhase::Complete(outcome));
        }
    };
    evidence = read_evidence(client, config, request.pull_request_number).await?;
    finish_approval_phase(request, sink, evidence, approval_recorded).await
}

async fn finish_approval_phase(
    request: &TaskBoardDependencyCompletionRequest,
    sink: &dyn TaskBoardDependencyCompletionSink,
    evidence: PullRequestEvidence,
    approval_recorded: bool,
) -> Result<ApprovalPhase, CliError> {
    if evidence.head_revision != request.verified_head_revision {
        return complete_pause(
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
    if evidence.gates.review.is_satisfied() {
        return Ok(ApprovalPhase::Continue);
    }
    if approval_recorded && !evidence.viewer_has_approved {
        return complete_pause(
            request,
            sink,
            &evidence,
            TaskBoardDependencyCompletionStatus::ApprovalSubmitted,
            format!(
                "waiting for GitHub to reflect automated approval on verified head {}",
                request.verified_head_revision
            ),
        )
        .await;
    }
    complete_pause(
        request,
        sink,
        &evidence,
        TaskBoardDependencyCompletionStatus::HumanRequired,
        unmet_approval_requirement(&evidence),
    )
    .await
}

async fn complete_pause(
    request: &TaskBoardDependencyCompletionRequest,
    sink: &dyn TaskBoardDependencyCompletionSink,
    evidence: &PullRequestEvidence,
    status: TaskBoardDependencyCompletionStatus,
    detail: String,
) -> Result<ApprovalPhase, CliError> {
    let outcome = pause(request, sink, evidence, status, detail).await?;
    Ok(ApprovalPhase::Complete(outcome))
}

enum ApprovalProgress {
    Submitted,
    AlreadyApplied,
    Paused(String),
    Blocked(Vec<ActionGateBlock>),
}

async fn submit_approval(
    request: &TaskBoardDependencyCompletionRequest,
    policy: &TaskBoardDependencyCompletionPolicy,
    config: &GitHubProjectConfig,
    client: &dyn GitHubAutomationClient,
    actions: &dyn PullRequestActionStore,
    evidence: &PullRequestEvidence,
) -> Result<ApprovalProgress, CliError> {
    if evidence.viewer_has_approved {
        return Ok(ApprovalProgress::Paused(unmet_approval_requirement(
            evidence,
        )));
    }
    if !policy.automated_approval_allowed {
        return Ok(ApprovalProgress::Paused(format!(
            "automated approval is not permitted by policy; {}",
            unmet_approval_requirement(evidence)
        )));
    }
    if !account_can_approve(evidence) {
        return Ok(ApprovalProgress::Paused(format!(
            "the configured GitHub account cannot approve this pull request; {}",
            unmet_approval_requirement(evidence)
        )));
    }
    let action = action(request, PullRequestActionKind::Approve);
    match begin_action(actions, action.clone()).await? {
        ActionAdmission::AlreadyApplied => return Ok(ApprovalProgress::AlreadyApplied),
        ActionAdmission::Abandoned => {
            return Ok(ApprovalProgress::Paused(
                "automated approval previously failed permanently".into(),
            ));
        }
        ActionAdmission::NeedsReconcile => {
            let admission =
                reconcile_action(actions, action.clone(), evidence.viewer_has_approved).await?;
            if admission == ActionAdmission::AlreadyApplied {
                return Ok(ApprovalProgress::AlreadyApplied);
            }
        }
        ActionAdmission::Proceed => {}
    }
    let read = PullRequestEvidenceRead::found(evidence.clone());
    if let ActionGateDecision::Blocked(blocks) = evaluate_action_gates(
        &read,
        &request.verified_head_revision,
        ActionGateRequirement::for_approval(),
    ) {
        finish_blocked(actions, &action.id, &blocks).await?;
        return Ok(ApprovalProgress::Blocked(blocks));
    }
    match client
        .approve_pull_request(
            config,
            request.pull_request_number,
            &request.verified_head_revision,
        )
        .await
    {
        Ok(()) => {
            finish_action(actions, &action.id, ActionOutcome::Succeeded).await?;
            Ok(ApprovalProgress::Submitted)
        }
        Err(error) => {
            finish_action(
                actions,
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
