use std::collections::{BTreeMap, BTreeSet};

use crate::errors::CliErrorKind;
use crate::task_board::github::{
    GitHubAutomation, GitHubAutomationClient, GitHubMergeEvidence, GitHubProjectConfig,
    GitHubPullRequestHandle, build_auto_merge_policy_input,
};
use crate::task_board::{
    PolicyAction, PolicyDecision, PolicyReasonCode, TaskBoardItem, TaskBoardStatus,
    TaskBoardWorkflowState,
};

#[cfg(test)]
use super::AutomationRequest;
use super::DatabaseAutomationRequest;
use super::support::{
    STEP_BRANCH_PUSHED, STEP_EVIDENCE_FAILED, STEP_MERGED, STEP_MISSING_WORKTREE, STEP_PR_FAILED,
    STEP_PUSH_FAILED, STEP_READY, STEP_WAITING_FOR_CHECKS, STEP_WAITING_FOR_COMMITS,
    STEP_WAITING_FOR_CONSENSUS, STEP_WAITING_FOR_HUMAN, STEP_WAITING_FOR_REVIEW, action_policy,
    branch_publication_async, clear_error, failure, is_repo_scoped, managed_branch_name,
    new_policy_trace_id, policy_blocked, push_branch_async, resolve_worktree, step, sync_labels,
    waiting,
};

mod pull_request;

use pull_request::prepare_pull_request_state;

#[cfg(test)]
pub(super) async fn automate_item(request: AutomationRequest<'_>) -> TaskBoardWorkflowState {
    let context = AutomationContext {
        policy: super::support::AutomationPolicy::LegacyRoot(request.board_root),
        config: request.config,
        item: request.item,
        client: request.client,
        host_id: request.host_id,
        expected_parent: None,
    };
    let mut prepared = match prepare_item(
        &context,
        request.project_dir,
        request.dry_run,
        request.session_worktrees,
    ) {
        AutomationFlow::Continue(prepared) => prepared,
        AutomationFlow::Done(workflow) => return workflow,
    };
    continue_automation(&context, &mut prepared).await
}

pub(super) async fn automate_item_with_database_policy(
    request: DatabaseAutomationRequest<'_>,
) -> TaskBoardWorkflowState {
    let context = AutomationContext {
        policy: super::support::AutomationPolicy::Database(request.policy),
        config: request.config,
        item: request.item,
        client: request.client,
        host_id: request.host_id,
        expected_parent: request.expected_parent,
    };
    let mut prepared = match prepare_item(
        &context,
        request.project_dir,
        request.dry_run,
        request.session_worktrees,
    ) {
        AutomationFlow::Continue(prepared) => prepared,
        AutomationFlow::Done(workflow) => return workflow,
    };
    continue_automation(&context, &mut prepared).await
}

async fn continue_automation(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
) -> TaskBoardWorkflowState {
    if let AutomationFlow::Done(workflow) = publish_branch(context, prepared).await {
        return workflow;
    }
    let pull_request_state = match prepare_pull_request_state(context, prepared).await {
        AutomationFlow::Continue(Some(pull_request_state)) => pull_request_state,
        AutomationFlow::Continue(None) => return prepared.workflow.clone(),
        AutomationFlow::Done(workflow) => return workflow,
    };
    if context.item.status != TaskBoardStatus::Done {
        return sync_labels_for_context(
            context,
            prepared,
            pull_request_state.pr_number,
            pull_request_state.desired_labels,
        )
        .await;
    }
    finish_done_item(
        context,
        prepared,
        pull_request_state.pr_number,
        &pull_request_state.pull_request,
        pull_request_state.desired_labels,
    )
    .await
}

async fn sync_labels_for_context(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pr_number: u64,
    desired_labels: BTreeSet<String>,
) -> TaskBoardWorkflowState {
    let decision = action_policy(
        context.policy,
        context.item,
        PolicyAction::Triage,
        Some(prepared.branch.as_str()),
        Some(pr_number),
        None,
    );
    if !decision.is_allow() {
        return policy_blocked(&mut prepared.workflow, PolicyAction::Triage, &decision);
    }
    sync_labels(
        context.config,
        context.client,
        pr_number,
        desired_labels,
        &mut prepared.workflow,
    )
    .await
}

struct AutomationContext<'a> {
    policy: super::support::AutomationPolicy<'a>,
    config: &'a GitHubProjectConfig,
    item: &'a TaskBoardItem,
    client: &'a dyn GitHubAutomationClient,
    host_id: &'a str,
    expected_parent: Option<&'a str>,
}

struct PreparedItem {
    workflow: TaskBoardWorkflowState,
    worktree: String,
    branch: String,
}

enum AutomationFlow<T> {
    Continue(T),
    Done(TaskBoardWorkflowState),
}

fn prepare_item(
    context: &AutomationContext<'_>,
    project_dir: Option<&str>,
    dry_run: bool,
    session_worktrees: &BTreeMap<String, String>,
) -> AutomationFlow<PreparedItem> {
    let mut workflow = context.item.workflow.clone();
    if !is_repo_scoped(context.item, context.config)
        || !matches!(
            context.item.status,
            TaskBoardStatus::InReview | TaskBoardStatus::Done
        )
    {
        return AutomationFlow::Done(workflow);
    }
    let Some(worktree) = resolve_worktree(
        context.item,
        &workflow,
        session_worktrees,
        project_dir,
        context.config,
    ) else {
        let error = CliErrorKind::workflow_io("task-board github worktree missing").into();
        return AutomationFlow::Done(failure(&mut workflow, STEP_MISSING_WORKTREE, &error));
    };
    if workflow.worktree.as_deref() != Some(worktree.as_str()) {
        workflow.worktree = Some(worktree.clone());
    }
    if !context
        .config
        .enabled_automations
        .enables(GitHubAutomation::CreateBranch)
    {
        return AutomationFlow::Done(workflow);
    }
    let branch = managed_branch_name(context.config, &context.item.id, context.host_id);
    if workflow.branch.as_deref() != Some(branch.as_str()) {
        workflow.branch = Some(branch.clone());
    }
    if dry_run {
        return AutomationFlow::Done(workflow);
    }
    if context.item.workflow.current_step_id.as_deref() == Some("review_changes_requested")
        && workflow.pr_number.is_none()
    {
        clear_error(&mut workflow);
        return AutomationFlow::Done(workflow);
    }
    AutomationFlow::Continue(PreparedItem {
        workflow,
        worktree,
        branch,
    })
}

async fn publish_branch(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
) -> AutomationFlow<()> {
    let publication = match branch_publication_async(
        context.client,
        prepared.worktree.clone(),
        context.config.clone(),
        prepared.branch.clone(),
        context.expected_parent,
    )
    .await
    {
        Ok(publication) => publication,
        Err(error) => {
            return AutomationFlow::Done(failure(&mut prepared.workflow, STEP_PUSH_FAILED, &error));
        }
    };
    if prepared.workflow.pr_number.is_none() && publication.waiting_for_commits {
        return AutomationFlow::Done(waiting(&mut prepared.workflow, STEP_WAITING_FOR_COMMITS));
    }
    if !publication.needs_push {
        return AutomationFlow::Continue(());
    }
    let decision = action_policy(
        context.policy,
        context.item,
        PolicyAction::PushBranch,
        Some(prepared.branch.as_str()),
        prepared.workflow.pr_number,
        None,
    );
    if !decision.is_allow() {
        return AutomationFlow::Done(policy_blocked(
            &mut prepared.workflow,
            PolicyAction::PushBranch,
            &decision,
        ));
    }
    if let Err(error) = push_branch_async(
        context.client,
        context.config,
        prepared.worktree.clone(),
        prepared.branch.clone(),
        context.expected_parent,
    )
    .await
    {
        return AutomationFlow::Done(failure(&mut prepared.workflow, STEP_PUSH_FAILED, &error));
    }
    step(&mut prepared.workflow, STEP_BRANCH_PUSHED);
    prepared
        .workflow
        .policy_trace_ids
        .push(new_policy_trace_id());
    AutomationFlow::Continue(())
}

async fn finish_done_item(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pr_number: u64,
    pull_request: &GitHubPullRequestHandle,
    desired_labels: BTreeSet<String>,
) -> TaskBoardWorkflowState {
    let watch_checks = context
        .config
        .enabled_automations
        .enables(GitHubAutomation::WatchChecks);
    let auto_merge = context
        .config
        .enabled_automations
        .enables(GitHubAutomation::AutoMerge);
    if !watch_checks && !auto_merge {
        return sync_labels_for_context(context, prepared, pr_number, desired_labels).await;
    }
    let evidence = match context
        .client
        .pull_request_merge_evidence(context.config, pr_number)
        .await
    {
        Ok(evidence) => evidence,
        Err(error) => {
            return failure(&mut prepared.workflow, STEP_EVIDENCE_FAILED, &error);
        }
    };
    if auto_merge {
        return auto_merge_item(
            context,
            prepared,
            pr_number,
            pull_request,
            evidence,
            desired_labels,
        )
        .await;
    }
    wait_for_merge_evidence(context, prepared, pr_number, &evidence, desired_labels).await
}

async fn auto_merge_item(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pr_number: u64,
    pull_request: &GitHubPullRequestHandle,
    evidence: GitHubMergeEvidence,
    mut desired_labels: BTreeSet<String>,
) -> TaskBoardWorkflowState {
    desired_labels.insert(context.config.labels.auto_merge.clone());
    let decision = action_policy(
        context.policy,
        context.item,
        PolicyAction::MergePr,
        Some(prepared.branch.as_str()),
        Some(pr_number),
        Some(&build_auto_merge_policy_input(context.config, &evidence)),
    );
    match decision {
        PolicyDecision::Allow { .. } => {
            if let Err(error) = context
                .client
                .merge_pull_request(
                    context.config,
                    pr_number,
                    context.config.merge_method,
                    Some(pull_request.head_sha.as_str()),
                )
                .await
            {
                return failure(&mut prepared.workflow, STEP_PR_FAILED, &error);
            }
            waiting(&mut prepared.workflow, STEP_MERGED);
            prepared
                .workflow
                .policy_trace_ids
                .push(new_policy_trace_id());
            prepared.workflow.clone()
        }
        decision => {
            apply_merge_block_decision(context, prepared, &mut desired_labels, &decision);
            sync_labels_for_context(context, prepared, pr_number, desired_labels).await
        }
    }
}

fn apply_merge_block_decision(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    desired_labels: &mut BTreeSet<String>,
    decision: &PolicyDecision,
) {
    match decision {
        &PolicyDecision::Deny { reason_code, .. } => match reason_code {
            PolicyReasonCode::ReviewerNotApproved
            | PolicyReasonCode::UnresolvedRequestedChanges => {
                desired_labels.insert(context.config.labels.needs_human.clone());
                waiting(&mut prepared.workflow, STEP_WAITING_FOR_REVIEW);
            }
            _ => {
                waiting(&mut prepared.workflow, STEP_WAITING_FOR_CHECKS);
            }
        },
        &PolicyDecision::RequireConsensus { .. } => {
            desired_labels.insert(context.config.labels.needs_human.clone());
            desired_labels.insert(context.config.labels.protected_path.clone());
            waiting(&mut prepared.workflow, STEP_WAITING_FOR_CONSENSUS);
        }
        &PolicyDecision::RequireHuman { .. } | &PolicyDecision::DryRunOnly { .. } => {
            desired_labels.insert(context.config.labels.needs_human.clone());
            waiting(&mut prepared.workflow, STEP_WAITING_FOR_HUMAN);
        }
        &PolicyDecision::Allow { .. } => {}
    }
    prepared
        .workflow
        .policy_trace_ids
        .push(new_policy_trace_id());
}

async fn wait_for_merge_evidence(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pr_number: u64,
    evidence: &GitHubMergeEvidence,
    mut desired_labels: BTreeSet<String>,
) -> TaskBoardWorkflowState {
    if !evidence.checks_green() {
        waiting(&mut prepared.workflow, STEP_WAITING_FOR_CHECKS);
    } else if !evidence.reviewer_verdict_approved() || evidence.unresolved_requested_changes() > 0 {
        desired_labels.insert(context.config.labels.needs_human.clone());
        waiting(&mut prepared.workflow, STEP_WAITING_FOR_REVIEW);
    } else {
        waiting(&mut prepared.workflow, STEP_READY);
    }
    sync_labels_for_context(context, prepared, pr_number, desired_labels).await
}
