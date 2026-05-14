use std::collections::BTreeSet;

use crate::task_board::github::{GitHubAutomation, GitHubPullRequestHandle};
use crate::task_board::{PolicyAction, TaskBoardStatus};

use super::super::support::{
    STEP_MERGED, STEP_PR_FAILED, STEP_PR_OPENED, STEP_REVIEW_FAILED, STEP_REVIEW_REQUESTED,
    action_policy, failure, new_policy_trace_id, policy_blocked, pull_request_request, step,
    update_pull_request_metadata, waiting,
};
use super::{AutomationContext, AutomationFlow, PreparedItem};

pub(super) struct PullRequestState {
    pub(super) pr_number: u64,
    pub(super) pull_request: GitHubPullRequestHandle,
    pub(super) desired_labels: BTreeSet<String>,
}

pub(super) async fn prepare_pull_request_state(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
) -> AutomationFlow<Option<PullRequestState>> {
    let pr_number = match ensure_pull_request(context, prepared).await {
        AutomationFlow::Continue(Some(pr_number)) => pr_number,
        AutomationFlow::Continue(None) => return AutomationFlow::Continue(None),
        AutomationFlow::Done(workflow) => return AutomationFlow::Done(workflow),
    };
    let mut desired_labels = BTreeSet::from([context.config.labels.managed.clone()]);
    let mut pull_request = match load_pull_request(context, prepared, pr_number).await {
        AutomationFlow::Continue(pull_request) => pull_request,
        AutomationFlow::Done(workflow) => return AutomationFlow::Done(workflow),
    };
    if pull_request.merged {
        return AutomationFlow::Done(waiting(&mut prepared.workflow, STEP_MERGED));
    }
    if context.item.status == TaskBoardStatus::InReview {
        desired_labels.insert(context.config.labels.needs_human.clone());
    }
    if let AutomationFlow::Done(workflow) =
        ready_pull_request(context, prepared, &mut pull_request, pr_number).await
    {
        return AutomationFlow::Done(workflow);
    }
    AutomationFlow::Continue(Some(PullRequestState {
        pr_number,
        pull_request,
        desired_labels,
    }))
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
