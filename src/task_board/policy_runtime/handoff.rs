#[cfg(test)]
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};

use super::action_persistence::PolicyActionPersistence;
#[cfg(test)]
use super::handoff_outbox::PolicyHandoffOutbox;
use super::handoff_outbox::handoff_record;
#[cfg(test)]
use super::inbox::PolicyEventInbox;
use super::models::{PolicyActionDescriptor, PolicyWorkflowEvent};
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
///
/// Beyond logging, the provider has two durable side effects: it appends the
/// handoff to a durable outbox (an auditable trail that survives a restart) and
/// publishes a wake-up event into the durable event inbox so a downstream run
/// waiting on this handoff can resume.
pub struct HandoffPolicyProvider {
    persistence: PolicyActionPersistence,
}

impl HandoffPolicyProvider {
    #[must_use]
    #[cfg(test)]
    pub fn new(root: PathBuf) -> Self {
        Self {
            persistence: PolicyActionPersistence::legacy_files(root),
        }
    }

    #[must_use]
    pub(crate) fn new_database(database: Arc<AsyncDaemonDb>) -> Self {
        Self {
            persistence: PolicyActionPersistence::database(database),
        }
    }
}

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

        let record = handoff_record(handoff_key, &ctx.workflow_id, &ctx.subject.key);
        let event = PolicyWorkflowEvent::named(&format!("handoff.{handoff_key}"), &ctx.subject.key);
        self.persistence.record_handoff(record, event).await?;

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
    use tempfile::tempdir;

    fn execution_context() -> PolicyExecutionContext {
        PolicyExecutionContext {
            workflow_id: "reviews_auto".to_owned(),
            subject: PolicyRunSubject::review_pr("owner/repo#1"),
            trigger: PolicyRunTrigger::Background,
        }
    }

    #[test]
    fn provider_domain_is_handoff() {
        let dir = tempdir().expect("tempdir");
        assert_eq!(
            HandoffPolicyProvider::new(dir.path().to_path_buf()).domain(),
            "handoff"
        );
    }

    #[tokio::test]
    async fn registry_dispatches_handoff_action_to_the_handoff_provider() {
        let dir = tempdir().expect("tempdir");
        let mut registry = PolicyProviderRegistry::default();
        registry.register(HandoffPolicyProvider::new(dir.path().to_path_buf()));
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
        let dir = tempdir().expect("tempdir");
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: None,
        };
        let execution = HandoffPolicyProvider::new(dir.path().to_path_buf())
            .execute(&action, &execution_context())
            .await
            .expect("execute handoff");
        assert_eq!(execution.action_key, HANDOFF_ACTION_KEY);
    }

    #[tokio::test]
    async fn execute_records_a_durable_handoff() {
        let dir = tempdir().expect("tempdir");
        let provider = HandoffPolicyProvider::new(dir.path().to_path_buf());
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
        };
        provider
            .execute(&action, &execution_context())
            .await
            .expect("execute handoff");

        let outbox = PolicyHandoffOutbox::new(dir.path().to_path_buf());
        let records = outbox.records().expect("records");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].handoff_key, "next-handler");
        assert_eq!(records[0].subject_key, "owner/repo#1");
    }

    #[tokio::test]
    async fn execute_publishes_a_handoff_event_into_the_inbox() {
        let dir = tempdir().expect("tempdir");
        let provider = HandoffPolicyProvider::new(dir.path().to_path_buf());
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
        };
        provider
            .execute(&action, &execution_context())
            .await
            .expect("execute handoff");

        let inbox = PolicyEventInbox::new(dir.path().to_path_buf());
        let pending = inbox.pending().expect("pending");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].event_key, "handoff.next-handler");
        assert_eq!(pending[0].subject_key, "owner/repo#1");
    }
}
