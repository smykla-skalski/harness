use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionResult, ReviewTarget,
};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::models::{
    PolicyActionDescriptor, PolicyRunRequest, PolicyRunStep, PolicyRunSubject, PolicyRunTrigger,
};
use crate::task_board::policy_runtime::providers::{
    PolicyActionExecution, PolicyActionProvider, PolicyExecutionContext,
};

use super::evidence::review_target_policy_evidence;
use super::events::checks_passed_wait;

const REVIEWS_PROVIDER: &str = "reviews";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ReviewsPolicyActionPayload {
    target: ReviewTarget,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    merge_method: Option<GitHubMergeMethod>,
}

#[async_trait]
pub(crate) trait ReviewsPolicyActionExecutor: Send + Sync {
    async fn approve(&self, target: &ReviewTarget) -> Result<(), CliError>;

    async fn merge(&self, target: &ReviewTarget, method: GitHubMergeMethod)
        -> Result<(), CliError>;
}

pub(crate) struct ReviewsPolicyProvider<E> {
    executor: E,
}

impl<E> ReviewsPolicyProvider<E> {
    #[must_use]
    pub(crate) fn new(executor: E) -> Self {
        Self { executor }
    }
}

#[async_trait]
impl<E> PolicyActionProvider for ReviewsPolicyProvider<E>
where
    E: ReviewsPolicyActionExecutor + Send + Sync,
{
    fn domain(&self) -> &'static str {
        REVIEWS_PROVIDER
    }

    async fn execute(
        &self,
        action: &PolicyActionDescriptor,
        _ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, CliError> {
        let payload = action_payload(action.payload.as_ref())?;
        match action.action_key.as_str() {
            "reviews.approve" => self.executor.approve(&payload.target).await?,
            "reviews.merge" => {
                self.executor
                    .merge(&payload.target, payload.merge_method.unwrap_or_default())
                    .await?
            }
            other => {
                return Err(CliErrorKind::invalid_transition(format!(
                    "unsupported reviews policy action '{other}'"
                ))
                .into());
            }
        }
        Ok(PolicyActionExecution {
            action_key: action.action_key.clone(),
        })
    }
}

pub(crate) async fn execute_reviews_auto_request<E>(
    provider: &ReviewsPolicyProvider<E>,
    request: PolicyRunRequest,
) -> Result<Vec<ReviewActionResult>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync,
{
    let PolicyRunRequest {
        workflow_id,
        subject,
        steps,
    } = request;
    let mut results = Vec::new();
    let ctx = PolicyExecutionContext {
        workflow_id,
        subject,
        trigger: PolicyRunTrigger::Manual,
    };
    let mut last_target = None;

    for (index, step) in steps.iter().enumerate() {
        match step {
            PolicyRunStep::Action(action) => {
                let payload = action_payload(action.payload.as_ref())?;
                let target = payload.target.clone();
                let action_kind = auto_action_kind(&action.action_key)?;
                let outcome = provider.execute(action, &ctx).await.map(|_| ());
                results.push(review_action_result(&target, action_kind, outcome));
                last_target = Some(target);
            }
            PolicyRunStep::Wait(wait) => {
                let Some(target) = last_target.as_ref() else {
                    continue;
                };
                let Some(next_action) = steps[index + 1..].iter().find_map(|step| match step {
                    PolicyRunStep::Action(action) => auto_action_kind(&action.action_key).ok(),
                    PolicyRunStep::Wait(_) => None,
                }) else {
                    continue;
                };
                results.push(ReviewActionResult {
                    repository: target.repository.clone(),
                    number: target.number,
                    action: next_action,
                    outcome: ReviewActionOutcome::Skipped,
                    message: Some(wait_message(wait)),
                    timeline_entry: None,
                });
                break;
            }
        }
    }

    Ok(results)
}

#[must_use]
pub(crate) fn reviews_auto_run_request(
    target: ReviewTarget,
    method: GitHubMergeMethod,
) -> PolicyRunRequest {
    let evidence = review_target_policy_evidence(&target);
    let can_approve = evidence.review_viewer_can_update == Some(true)
        && evidence.review_is_open == Some(true)
        && evidence.checks_green == Some(true)
        && evidence.review_has_merge_conflicts == Some(false)
        && matches!(
            (
                evidence.review_review_required,
                evidence.review_has_no_decision,
            ),
            (Some(true), _) | (_, Some(true))
        );
    let can_merge = evidence.review_viewer_can_update == Some(true)
        && evidence.review_is_open == Some(true)
        && evidence.review_is_draft == Some(false)
        && evidence.checks_green == Some(true)
        && evidence.review_has_merge_conflicts == Some(false)
        && evidence.review_policy_blocked == Some(false)
        && matches!(
            (
                evidence.reviewer_verdict_approved,
                evidence.review_has_no_decision,
            ),
            (Some(true), _) | (_, Some(true))
        );
    let mut steps = Vec::new();
    if can_approve {
        steps.push(PolicyRunStep::Action(policy_action(
            "reviews.approve",
            &target,
            None,
        )));
        steps.push(PolicyRunStep::Wait(checks_passed_wait()));
        steps.push(PolicyRunStep::Action(policy_action(
            "reviews.merge",
            &target,
            Some(method),
        )));
    } else if can_merge {
        steps.push(PolicyRunStep::Action(policy_action(
            "reviews.merge",
            &target,
            Some(method),
        )));
    }

    PolicyRunRequest {
        workflow_id: "reviews_auto".to_owned(),
        subject: PolicyRunSubject::review_pr(&format!("{}#{}", target.repository, target.number)),
        steps,
    }
}

fn policy_action(
    action_key: &str,
    target: &ReviewTarget,
    merge_method: Option<GitHubMergeMethod>,
) -> PolicyActionDescriptor {
    PolicyActionDescriptor {
        provider: REVIEWS_PROVIDER.to_owned(),
        action_key: action_key.to_owned(),
        payload: Some(
            serde_json::to_value(ReviewsPolicyActionPayload {
                target: target.clone(),
                merge_method,
            })
            .expect("serialize reviews policy action payload"),
        ),
    }
}

fn auto_action_kind(action_key: &str) -> Result<ReviewActionKind, CliError> {
    match action_key {
        "reviews.approve" => Ok(ReviewActionKind::AutoApprove),
        "reviews.merge" => Ok(ReviewActionKind::AutoMerge),
        other => Err(CliErrorKind::invalid_transition(format!(
            "unsupported reviews auto action '{other}'"
        ))
        .into()),
    }
}

fn wait_message(wait: &PolicyWaitCondition) -> String {
    match wait {
        PolicyWaitCondition::Timer { duration_seconds } => {
            format!("waiting {duration_seconds}s before continuing the policy workflow")
        }
        PolicyWaitCondition::Event { event_key } => {
            format!("waiting for policy event '{event_key}' before continuing")
        }
    }
}

fn review_action_result(
    target: &ReviewTarget,
    action: ReviewActionKind,
    result: Result<(), CliError>,
) -> ReviewActionResult {
    match result {
        Ok(()) => ReviewActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action,
            outcome: ReviewActionOutcome::Applied,
            message: None,
            timeline_entry: None,
        },
        Err(error) => ReviewActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action,
            outcome: ReviewActionOutcome::Failed,
            message: Some(error.to_string()),
            timeline_entry: None,
        },
    }
}

fn action_payload(
    payload: Option<&serde_json::Value>,
) -> Result<ReviewsPolicyActionPayload, CliError> {
    let payload = payload.ok_or_else(|| {
        CliErrorKind::invalid_transition("reviews policy action payload is required".to_owned())
    })?;
    serde_json::from_value(payload.clone()).map_err(|error| {
        CliErrorKind::invalid_transition(format!(
            "invalid reviews policy action payload: {error}"
        ))
        .into()
    })
}
