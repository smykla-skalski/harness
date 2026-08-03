use std::collections::BTreeSet;
use std::mem;

use crate::task_board::github::{GitHubAutomation, GitHubPullRequestHandle};
use crate::task_board::{PolicyAction, TaskBoardStatus};
use harness_kernel::errors::CliError;

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
) -> Result<AutomationFlow<Option<PullRequestState>>, CliError> {
    let pr_number = match ensure_pull_request(context, prepared).await? {
        AutomationFlow::Continue(Some(pr_number)) => pr_number,
        AutomationFlow::Continue(None) => return Ok(AutomationFlow::Continue(None)),
        AutomationFlow::Done(workflow) => return Ok(AutomationFlow::Done(workflow)),
    };
    let mut desired_labels = BTreeSet::from([context.config.labels.managed.clone()]);
    let mut pull_request = match load_pull_request(context, prepared, pr_number).await? {
        AutomationFlow::Continue(pull_request) => pull_request,
        AutomationFlow::Done(workflow) => return Ok(AutomationFlow::Done(workflow)),
    };
    if pull_request.merged {
        return Ok(AutomationFlow::Done(Box::new(waiting(
            &mut prepared.workflow,
            STEP_MERGED,
        ))));
    }
    if context.item.status == TaskBoardStatus::InReview {
        desired_labels.insert(context.config.labels.needs_human.clone());
    }
    if let AutomationFlow::Done(workflow) =
        ready_pull_request(context, prepared, &mut pull_request, pr_number).await?
    {
        return Ok(AutomationFlow::Done(workflow));
    }
    Ok(AutomationFlow::Continue(Some(PullRequestState {
        pr_number,
        pull_request,
        desired_labels,
    })))
}

async fn ensure_pull_request(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
) -> Result<AutomationFlow<Option<u64>>, CliError> {
    if prepared.workflow.pr_number.is_some()
        || !context
            .config
            .enabled_automations
            .enables(GitHubAutomation::OpenPullRequest)
    {
        return Ok(AutomationFlow::Continue(prepared.workflow.pr_number));
    }
    let decision = action_policy(
        context.policy,
        context.item,
        PolicyAction::OpenPr,
        Some(prepared.branch.as_str()),
        None,
        None,
    );
    if !decision.is_allow() {
        return Ok(AutomationFlow::Done(Box::new(policy_blocked(
            &mut prepared.workflow,
            PolicyAction::OpenPr,
            &decision,
        ))));
    }
    context.ensure_active().await?;
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
            context.ensure_active().await?;
            Ok(AutomationFlow::Continue(prepared.workflow.pr_number))
        }
        Err(error) => Ok(AutomationFlow::Done(Box::new(failure(
            &mut prepared.workflow,
            STEP_PR_FAILED,
            &error,
        )))),
    }
}

async fn load_pull_request(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pr_number: u64,
) -> Result<AutomationFlow<GitHubPullRequestHandle>, CliError> {
    match context
        .client
        .get_pull_request(context.config, pr_number)
        .await
    {
        Ok(pull_request) => {
            context.ensure_active().await?;
            update_pull_request_metadata(&mut prepared.workflow, &pull_request);
            Ok(AutomationFlow::Continue(pull_request))
        }
        Err(error) => Ok(AutomationFlow::Done(Box::new(failure(
            &mut prepared.workflow,
            STEP_PR_FAILED,
            &error,
        )))),
    }
}

async fn ready_pull_request(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pull_request: &mut GitHubPullRequestHandle,
    pr_number: u64,
) -> Result<AutomationFlow<()>, CliError> {
    if !context
        .config
        .enabled_automations
        .enables(GitHubAutomation::RequestReview)
    {
        return Ok(AutomationFlow::Continue(()));
    }
    let mut reviewers = missing_reviewers(
        context.config.requested_reviewers.normalized_reviewers(),
        &pull_request.requested_reviewers,
    );
    let mut team_reviewers = missing_reviewers(
        context
            .config
            .requested_reviewers
            .normalized_team_reviewers(),
        &pull_request.requested_team_reviewers,
    );
    if !pull_request.draft && reviewers.is_empty() && team_reviewers.is_empty() {
        return Ok(AutomationFlow::Continue(()));
    }
    let decision = action_policy(
        context.policy,
        context.item,
        PolicyAction::SubmitReview,
        Some(prepared.branch.as_str()),
        Some(pr_number),
        None,
    );
    if !decision.is_allow() {
        return Ok(AutomationFlow::Done(Box::new(policy_blocked(
            &mut prepared.workflow,
            PolicyAction::SubmitReview,
            &decision,
        ))));
    }
    if let AutomationFlow::Done(workflow) = ready_draft_pull_request(
        context,
        prepared,
        pull_request,
        pr_number,
        &mut reviewers,
        &mut team_reviewers,
    )
    .await?
    {
        return Ok(AutomationFlow::Done(workflow));
    }
    if !reviewers.is_empty() || !team_reviewers.is_empty() {
        context.ensure_active().await?;
        match context
            .client
            .request_pull_request_reviewers(context.config, pr_number, &reviewers, &team_reviewers)
            .await
        {
            Ok(()) => context.ensure_active().await?,
            Err(error) => {
                return Ok(AutomationFlow::Done(Box::new(failure(
                    &mut prepared.workflow,
                    STEP_REVIEW_FAILED,
                    &error,
                ))));
            }
        }
    }
    step(&mut prepared.workflow, STEP_REVIEW_REQUESTED);
    prepared
        .workflow
        .policy_trace_ids
        .push(new_policy_trace_id());
    Ok(AutomationFlow::Continue(()))
}

async fn ready_draft_pull_request(
    context: &AutomationContext<'_>,
    prepared: &mut PreparedItem,
    pull_request: &mut GitHubPullRequestHandle,
    pr_number: u64,
    reviewers: &mut Vec<String>,
    team_reviewers: &mut Vec<String>,
) -> Result<AutomationFlow<()>, CliError> {
    if !pull_request.draft {
        return Ok(AutomationFlow::Continue(()));
    }
    context.ensure_active().await?;
    match context
        .client
        .ready_pull_request_for_review(context.config, pr_number)
        .await
    {
        Ok(updated_pull_request) => {
            context.ensure_active().await?;
            *pull_request = updated_pull_request;
            *reviewers = missing_reviewers(mem::take(reviewers), &pull_request.requested_reviewers);
            *team_reviewers = missing_reviewers(
                mem::take(team_reviewers),
                &pull_request.requested_team_reviewers,
            );
            update_pull_request_metadata(&mut prepared.workflow, pull_request);
            Ok(AutomationFlow::Continue(()))
        }
        Err(error) => Ok(AutomationFlow::Done(Box::new(failure(
            &mut prepared.workflow,
            STEP_REVIEW_FAILED,
            &error,
        )))),
    }
}

fn missing_reviewers(configured: Vec<String>, requested: &[String]) -> Vec<String> {
    let requested = requested
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    configured
        .into_iter()
        .filter(|reviewer| !requested.contains(reviewer.as_str()))
        .collect()
}
