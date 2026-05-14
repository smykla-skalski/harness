use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::errors::CliErrorKind;
use crate::task_board::github::{
    GitHubAutomation, GitHubAutomationClient, GitHubMergeEvidence, GitHubProjectConfig,
    GitHubPullRequestHandle, build_auto_merge_policy_input,
};
use crate::task_board::{
    PolicyAction, PolicyDecision, PolicyReasonCode, TaskBoardItem, TaskBoardStatus,
    TaskBoardWorkflowState,
};

use super::support::{
    STEP_BRANCH_PUSHED, STEP_EVIDENCE_FAILED, STEP_MERGED, STEP_MISSING_WORKTREE, STEP_PR_FAILED,
    STEP_PR_OPENED, STEP_PUSH_FAILED, STEP_READY, STEP_REVIEW_FAILED, STEP_REVIEW_REQUESTED,
    STEP_WAITING_FOR_CHECKS, STEP_WAITING_FOR_COMMITS, STEP_WAITING_FOR_CONSENSUS,
    STEP_WAITING_FOR_HUMAN, STEP_WAITING_FOR_REVIEW, action_policy, branch_publication_async,
    clear_error, failure, is_repo_scoped, managed_branch_name, new_policy_trace_id, policy_blocked,
    pull_request_request, push_branch_async, resolve_worktree, step, sync_labels,
    update_pull_request_metadata, waiting,
};

pub(super) async fn automate_item(
    board_root: &Path,
    config: &GitHubProjectConfig,
    project_dir: Option<&str>,
    dry_run: bool,
    item: &TaskBoardItem,
    session_worktrees: &BTreeMap<String, String>,
    github_token: Option<&str>,
    client: &dyn GitHubAutomationClient,
) -> TaskBoardWorkflowState {
    let context = AutomationContext {
        board_root,
        config,
        item,
        github_token,
        client,
    };
    let mut prepared = match prepare_item(&context, project_dir, dry_run, session_worktrees) {
        AutomationFlow::Continue(prepared) => prepared,
        AutomationFlow::Done(workflow) => return workflow,
    };
    if let AutomationFlow::Done(workflow) = publish_branch(&context, &mut prepared).await {
        return workflow;
    }
    let pr_number = match ensure_pull_request(&context, &mut prepared).await {
        AutomationFlow::Continue(Some(pr_number)) => pr_number,
        AutomationFlow::Continue(None) => return prepared.workflow,
        AutomationFlow::Done(workflow) => return workflow,
    };
    let mut desired_labels = BTreeSet::from([context.config.labels.managed.clone()]);
    let mut pull_request = match load_pull_request(&context, &mut prepared, pr_number).await {
        AutomationFlow::Continue(pull_request) => pull_request,
        AutomationFlow::Done(workflow) => return workflow,
    };
    if pull_request.merged {
        return waiting(&mut prepared.workflow, STEP_MERGED);
    }
    if context.item.status == TaskBoardStatus::InReview {
        desired_labels.insert(context.config.labels.needs_human.clone());
    }
    if let AutomationFlow::Done(workflow) =
        ready_pull_request(&context, &mut prepared, &mut pull_request, pr_number).await
    {
        return workflow;
    }
    if context.item.status != TaskBoardStatus::Done {
        return sync_labels(
            context.config,
            context.client,
            pr_number,
            desired_labels,
            &mut prepared.workflow,
        )
        .await;
    }
    finish_done_item(
        &context,
        &mut prepared,
        pr_number,
        &pull_request,
        desired_labels,
    )
    .await
}

struct AutomationContext<'a> {
    board_root: &'a Path,
    config: &'a GitHubProjectConfig,
    item: &'a TaskBoardItem,
    github_token: Option<&'a str>,
    client: &'a dyn GitHubAutomationClient,
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
    let branch = managed_branch_name(context.config, &context.item.id);
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
        prepared.worktree.clone(),
        context.config.clone(),
        prepared.branch.clone(),
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
        context.board_root,
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
        prepared.worktree.clone(),
        publication.remote,
        prepared.branch.clone(),
        context.github_token.map(ToOwned::to_owned),
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

async fn ensure_pull_request(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
) -> AutomationFlow<Option<u64>> {
    if prepared.workflow.pr_number.is_some()
        || !context
            .config
            .enabled_automations
            .enables(GitHubAutomation::OpenPullRequest)
    {
        return AutomationFlow::Continue(prepared.workflow.pr_number);
    }
    let decision = action_policy(
        context.board_root,
        context.item,
        PolicyAction::OpenPr,
        Some(prepared.branch.as_str()),
        None,
        None,
    );
    if !decision.is_allow() {
        return AutomationFlow::Done(policy_blocked(
            &mut prepared.workflow,
            PolicyAction::OpenPr,
            &decision,
        ));
    }
    match context
        .client
        .ensure_pull_request(
            context.config,
            &pull_request_request(context.item, context.config, &prepared.branch),
        )
        .await
    {
        Ok(pull_request) => {
            update_pull_request_metadata(&mut prepared.workflow, &pull_request);
            step(&mut prepared.workflow, STEP_PR_OPENED);
            prepared
                .workflow
                .policy_trace_ids
                .push(new_policy_trace_id());
            AutomationFlow::Continue(prepared.workflow.pr_number)
        }
        Err(error) => AutomationFlow::Done(failure(&mut prepared.workflow, STEP_PR_FAILED, &error)),
    }
}

async fn load_pull_request(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pr_number: u64,
) -> AutomationFlow<GitHubPullRequestHandle> {
    match context
        .client
        .get_pull_request(context.config, pr_number)
        .await
    {
        Ok(pull_request) => {
            update_pull_request_metadata(&mut prepared.workflow, &pull_request);
            AutomationFlow::Continue(pull_request)
        }
        Err(error) => AutomationFlow::Done(failure(&mut prepared.workflow, STEP_PR_FAILED, &error)),
    }
}

async fn ready_pull_request(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pull_request: &mut GitHubPullRequestHandle,
    pr_number: u64,
) -> AutomationFlow<()> {
    if !pull_request.draft
        || !context
            .config
            .enabled_automations
            .enables(GitHubAutomation::RequestReview)
    {
        return AutomationFlow::Continue(());
    }
    let decision = action_policy(
        context.board_root,
        context.item,
        PolicyAction::SubmitReview,
        Some(prepared.branch.as_str()),
        Some(pr_number),
        None,
    );
    if !decision.is_allow() {
        return AutomationFlow::Done(policy_blocked(
            &mut prepared.workflow,
            PolicyAction::SubmitReview,
            &decision,
        ));
    }
    match context
        .client
        .ready_pull_request_for_review(context.config, pr_number)
        .await
    {
        Ok(updated_pull_request) => {
            *pull_request = updated_pull_request;
            update_pull_request_metadata(&mut prepared.workflow, pull_request);
            step(&mut prepared.workflow, STEP_REVIEW_REQUESTED);
            prepared
                .workflow
                .policy_trace_ids
                .push(new_policy_trace_id());
            AutomationFlow::Continue(())
        }
        Err(error) => {
            AutomationFlow::Done(failure(&mut prepared.workflow, STEP_REVIEW_FAILED, &error))
        }
    }
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
        return sync_labels(
            context.config,
            context.client,
            pr_number,
            desired_labels,
            &mut prepared.workflow,
        )
        .await;
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
        context.board_root,
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
            apply_merge_block_decision(context, prepared, &mut desired_labels, decision);
            sync_labels(
                context.config,
                context.client,
                pr_number,
                desired_labels,
                &mut prepared.workflow,
            )
            .await
        }
    }
}

fn apply_merge_block_decision(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    desired_labels: &mut BTreeSet<String>,
    decision: PolicyDecision,
) {
    match decision {
        PolicyDecision::Deny { reason_code, .. } => match reason_code {
            PolicyReasonCode::ReviewerNotApproved
            | PolicyReasonCode::UnresolvedRequestedChanges => {
                desired_labels.insert(context.config.labels.needs_human.clone());
                waiting(&mut prepared.workflow, STEP_WAITING_FOR_REVIEW);
            }
            _ => {
                waiting(&mut prepared.workflow, STEP_WAITING_FOR_CHECKS);
            }
        },
        PolicyDecision::RequireConsensus { .. } => {
            desired_labels.insert(context.config.labels.needs_human.clone());
            desired_labels.insert(context.config.labels.protected_path.clone());
            waiting(&mut prepared.workflow, STEP_WAITING_FOR_CONSENSUS);
        }
        PolicyDecision::RequireHuman { .. } | PolicyDecision::DryRunOnly { .. } => {
            desired_labels.insert(context.config.labels.needs_human.clone());
            waiting(&mut prepared.workflow, STEP_WAITING_FOR_HUMAN);
        }
        PolicyDecision::Allow { .. } => {}
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
    sync_labels(
        context.config,
        context.client,
        pr_number,
        desired_labels,
        &mut prepared.workflow,
    )
    .await
}
