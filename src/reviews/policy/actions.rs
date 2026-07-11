use std::path::Path;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::ReviewTarget;
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy::{
    PolicyAction, PolicyDecision, PolicyInput, PolicyReasonCode, PolicySubject,
};
use crate::task_board::policy_graph::{
    CompiledWorkflowStep, PolicyGraph, PolicyGraphMode, cached_gate_policy,
};
use crate::task_board::policy_runtime::handoff::{HANDOFF_ACTION_KEY, HANDOFF_PROVIDER};
use crate::task_board::policy_runtime::models::{
    PolicyActionDescriptor, PolicyRunRequest, PolicyRunStep, PolicyRunSubject,
};
use crate::task_board::policy_runtime::notification::{
    NOTIFICATION_ACTION_KEY, NOTIFICATION_PROVIDER,
};
use crate::task_board::policy_runtime::providers::{
    PolicyActionExecution, PolicyActionProvider, PolicyExecutionContext,
};

use super::evidence::review_target_policy_evidence;
const REVIEWS_PROVIDER: &str = "reviews";

#[derive(Debug, Clone)]
pub(crate) struct ReviewsPolicyPlan {
    pub workflow_id: String,
    pub subject: PolicyRunSubject,
    pub subject_fingerprint: Option<String>,
    pub steps: Vec<PolicyRunStep>,
    pub actionable: bool,
    pub reason: Option<String>,
}

impl ReviewsPolicyPlan {
    #[must_use]
    pub(crate) fn into_run_request(self) -> Option<PolicyRunRequest> {
        if !self.actionable {
            return None;
        }
        Some(PolicyRunRequest {
            workflow_id: self.workflow_id,
            subject: self.subject,
            subject_fingerprint: self.subject_fingerprint,
            steps: self.steps,
        })
    }
}

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
                    .await?;
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

pub(crate) fn authored_reviews_policy_plan(
    root: &Path,
    workflow_id: &str,
    target: &ReviewTarget,
    method: GitHubMergeMethod,
) -> Result<ReviewsPolicyPlan, CliError> {
    let workflow_id = workflow_id.trim().to_ascii_lowercase();
    let subject = PolicyRunSubject::review_pr(&format!("{}#{}", target.repository, target.number));
    let subject_fingerprint = Some(target.head_sha.clone());
    let Some(document) = enforced_reviews_policy_document(root) else {
        return Ok(ReviewsPolicyPlan {
            workflow_id,
            subject,
            subject_fingerprint,
            steps: Vec::new(),
            actionable: false,
            reason: Some(
                "reviews policy workflow is disabled because no enforced policy canvas is active"
                    .to_owned(),
            ),
        });
    };
    let validation = document.validate();
    if !validation.is_valid() {
        return Ok(ReviewsPolicyPlan {
            workflow_id,
            subject,
            subject_fingerprint,
            steps: Vec::new(),
            actionable: false,
            reason: Some(format!(
                "active policy canvas is invalid: {} validation issue(s)",
                validation.issues.len()
            )),
        });
    }
    let input = PolicyInput {
        workflow: Some(workflow_id.clone()),
        action: PolicyAction::SubmitReview,
        subject: policy_subject(target),
        evidence: review_target_policy_evidence(target),
    };
    let Some(compiled) = document.compile_workflow(&workflow_id, &input) else {
        return Ok(ReviewsPolicyPlan {
            workflow_id: workflow_id.clone(),
            subject,
            subject_fingerprint,
            steps: Vec::new(),
            actionable: false,
            reason: Some(format!(
                "active policy canvas does not define a '{workflow_id}' workflow"
            )),
        });
    };

    let mut steps = Vec::new();
    for step in &compiled.steps {
        match step {
            CompiledWorkflowStep::Action { action_id } => {
                steps.push(PolicyRunStep::Action(workflow_action(
                    action_id, target, method,
                )?));
            }
            CompiledWorkflowStep::Wait(wait) => {
                steps.push(PolicyRunStep::Wait(wait.clone()));
            }
            CompiledWorkflowStep::Handoff { handoff_key } => {
                steps.push(PolicyRunStep::Action(handoff_action(handoff_key)));
            }
        }
    }

    if let Some(reason) = compiled.blocked_reason {
        return Ok(ReviewsPolicyPlan {
            workflow_id,
            subject,
            subject_fingerprint,
            steps,
            actionable: false,
            reason: Some(reason),
        });
    }

    let decision_reason = match compiled.decision {
        PolicyDecision::Allow { .. } => None,
        PolicyDecision::Deny { reason_code, .. }
        | PolicyDecision::RequireHuman { reason_code, .. }
        | PolicyDecision::RequireConsensus { reason_code, .. }
        | PolicyDecision::DryRunOnly { reason_code, .. } => {
            Some(policy_reason_message(reason_code).to_owned())
        }
    };
    let actionable = decision_reason.is_none() && !steps.is_empty();
    let reason = if let Some(reason) = decision_reason {
        Some(reason)
    } else if steps.is_empty() {
        Some("reviews policy workflow produced no executable steps".to_owned())
    } else {
        None
    };

    Ok(ReviewsPolicyPlan {
        workflow_id,
        subject,
        subject_fingerprint,
        steps,
        actionable,
        reason,
    })
}

fn enforced_reviews_policy_document(root: &Path) -> Option<PolicyGraph> {
    let document = cached_gate_policy(root)?;
    (document.mode == PolicyGraphMode::Enforced).then(|| (**document).clone())
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

fn handoff_action(handoff_key: &str) -> PolicyActionDescriptor {
    PolicyActionDescriptor {
        provider: HANDOFF_PROVIDER.to_owned(),
        action_key: HANDOFF_ACTION_KEY.to_owned(),
        payload: Some(serde_json::json!({ "handoff_key": handoff_key })),
    }
}

fn notification_action(target: &ReviewTarget) -> PolicyActionDescriptor {
    PolicyActionDescriptor {
        provider: NOTIFICATION_PROVIDER.to_owned(),
        action_key: NOTIFICATION_ACTION_KEY.to_owned(),
        payload: Some(serde_json::json!({
            "channel": "reviews",
            "message": format!(
                "{}#{} has merge conflicts or conflict markers",
                target.repository, target.number
            ),
        })),
    }
}

fn workflow_action(
    action_key: &str,
    target: &ReviewTarget,
    method: GitHubMergeMethod,
) -> Result<PolicyActionDescriptor, CliError> {
    match action_key {
        "reviews.approve" => Ok(policy_action("reviews.approve", target, None)),
        "reviews.merge" => Ok(policy_action("reviews.merge", target, Some(method))),
        NOTIFICATION_ACTION_KEY => Ok(notification_action(target)),
        other => Err(CliErrorKind::invalid_transition(format!(
            "unsupported reviews policy action '{other}'"
        ))
        .into()),
    }
}

fn policy_subject(target: &ReviewTarget) -> PolicySubject {
    PolicySubject {
        repository: Some(target.repository.clone()),
        pull_request: Some(target.number.to_string()),
        ..PolicySubject::default()
    }
}

fn policy_reason_message(reason_code: PolicyReasonCode) -> &'static str {
    match reason_code {
        PolicyReasonCode::DefaultAllow => {
            "reviews policy workflow resolved without any executable steps"
        }
        PolicyReasonCode::AutoMergeAllowed => "reviews policy workflow is allowed to continue",
        PolicyReasonCode::MissingMergeEvidence => {
            "reviews policy workflow is missing required merge evidence"
        }
        PolicyReasonCode::ChecksNotGreen => {
            "reviews policy workflow is waiting for required checks to pass"
        }
        PolicyReasonCode::BranchProtectionBlocked => {
            "reviews policy workflow is blocked by branch protection"
        }
        PolicyReasonCode::ReviewerNotApproved => {
            "reviews policy workflow requires an approved review"
        }
        PolicyReasonCode::UnresolvedRequestedChanges => {
            "reviews policy workflow is blocked by unresolved requested changes"
        }
        PolicyReasonCode::ProtectedPathTouched => {
            "reviews policy workflow is blocked because protected paths were touched"
        }
        PolicyReasonCode::RiskAboveThreshold => {
            "reviews policy workflow exceeded the configured risk threshold"
        }
        PolicyReasonCode::HumanRequired => {
            "reviews policy workflow requires a human decision before continuing"
        }
        PolicyReasonCode::DryRunRequired => {
            "reviews policy workflow is configured for dry-run only"
        }
    }
}

fn action_payload(
    payload: Option<&serde_json::Value>,
) -> Result<ReviewsPolicyActionPayload, CliError> {
    let payload = payload.ok_or_else(|| {
        CliErrorKind::invalid_transition("reviews policy action payload is required".to_owned())
    })?;
    serde_json::from_value(payload.clone()).map_err(|error| {
        CliErrorKind::invalid_transition(format!("invalid reviews policy action payload: {error}"))
            .into()
    })
}

pub(crate) fn planned_reviews_policy_run_matches_target(
    steps: &[PolicyRunStep],
    target: &ReviewTarget,
) -> bool {
    steps.iter().any(|step| {
        let PolicyRunStep::Action(action) = step else {
            return false;
        };
        if action.provider != REVIEWS_PROVIDER {
            return false;
        }
        action_payload(action.payload.as_ref()).is_ok_and(|payload| {
            payload.target.repository == target.repository
                && payload.target.number == target.number
                && payload.target.head_sha == target.head_sha
        })
    })
}
