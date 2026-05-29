use async_trait::async_trait;
use serde::Deserialize;

use crate::errors::{CliError, CliErrorKind};

use super::models::PolicyActionDescriptor;
use super::providers::{PolicyActionExecution, PolicyActionProvider, PolicyExecutionContext};

/// Provider domain for cross-cutting orchestration handoffs.
pub const HANDOFF_PROVIDER: &str = "handoff";
/// Action key that a compiled handoff step dispatches to.
pub const HANDOFF_ACTION_KEY: &str = "handoff.emit";

#[derive(Debug, Default, Deserialize)]
struct HandoffActionPayload {
    #[serde(default)]
    handoff_key: String,
}

/// A domain-agnostic orchestration provider that records a workflow handoff. It
/// proves the provider registry dispatches beyond the reviews domain: a Handoff
/// node authored in any workflow compiles to a `handoff` action and runs through
/// this provider in production alongside the reviews provider.
pub struct HandoffPolicyProvider;

#[async_trait]
impl PolicyActionProvider for HandoffPolicyProvider {
    fn domain(&self) -> &'static str {
        HANDOFF_PROVIDER
    }

    async fn execute(
        &self,
        action: &PolicyActionDescriptor,
        ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, CliError> {
        let payload = handoff_payload(action.payload.as_ref())?;
        let handoff_key = if payload.handoff_key.trim().is_empty() {
            "unspecified"
        } else {
            payload.handoff_key.trim()
        };
        tracing::info!(
            workflow_id = %ctx.workflow_id,
            subject = %ctx.subject.key,
            handoff_key,
            "policy workflow emitted handoff"
        );
        Ok(PolicyActionExecution {
            action_key: action.action_key.clone(),
        })
    }
}

fn handoff_payload(payload: Option<&serde_json::Value>) -> Result<HandoffActionPayload, CliError> {
    match payload {
        None => Ok(HandoffActionPayload::default()),
        Some(payload) => serde_json::from_value(payload.clone()).map_err(|error| {
            CliErrorKind::invalid_transition(format!("invalid handoff action payload: {error}"))
                .into()
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::policy_runtime::models::{PolicyRunSubject, PolicyRunTrigger};
    use crate::task_board::policy_runtime::providers::PolicyProviderRegistry;

    fn execution_context() -> PolicyExecutionContext {
        PolicyExecutionContext {
            workflow_id: "reviews_auto".to_owned(),
            subject: PolicyRunSubject::review_pr("owner/repo#1"),
            trigger: PolicyRunTrigger::Background,
        }
    }

    #[test]
    fn provider_domain_is_handoff() {
        assert_eq!(HandoffPolicyProvider.domain(), "handoff");
    }

    #[tokio::test]
    async fn registry_dispatches_handoff_action_to_the_handoff_provider() {
        let mut registry = PolicyProviderRegistry::default();
        registry.register(HandoffPolicyProvider);
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
        };
        let execution = registry
            .execute(&action, &execution_context())
            .await
            .expect("dispatch handoff");
        assert_eq!(execution.action_key, HANDOFF_ACTION_KEY);
    }

    #[tokio::test]
    async fn handoff_without_a_payload_still_succeeds() {
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: None,
        };
        let execution = HandoffPolicyProvider
            .execute(&action, &execution_context())
            .await
            .expect("execute handoff");
        assert_eq!(execution.action_key, HANDOFF_ACTION_KEY);
    }
}
