use std::path::PathBuf;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::workspace::utc_now;

use super::models::PolicyActionDescriptor;
use super::providers::{PolicyActionExecution, PolicyActionProvider, PolicyExecutionContext};

/// Provider domain for cross-cutting task-board task creation.
pub const TASK_CREATION_PROVIDER: &str = "task_board";
/// Action key that a compiled task-creation step dispatches to.
pub const TASK_CREATION_ACTION_KEY: &str = "task_board.create";

pub const POLICY_TASK_CREATION_OUTBOX_SCHEMA_VERSION: u32 = 1;

/// Records older than this are pruned on append so a task-creation trail that is
/// never drained downstream cannot accumulate forever.
const TASK_CREATION_RETENTION_SECONDS: i64 = 3600;

#[derive(Debug, Default, Deserialize)]
struct TaskCreationActionPayload {
    #[serde(default)]
    title: String,
    #[serde(default)]
    body: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskCreationRecord {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    pub workflow_id: String,
    pub subject_key: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyTaskCreationOutboxDocument {
    pub schema_version: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub records: Vec<TaskCreationRecord>,
}

impl Default for PolicyTaskCreationOutboxDocument {
    fn default() -> Self {
        Self {
            schema_version: POLICY_TASK_CREATION_OUTBOX_SCHEMA_VERSION,
            records: Vec::new(),
        }
    }
}

/// A durable, append-only trail of tasks a policy workflow asked to create on
/// the task board. Recording them durably means the request survives a daemon
/// restart and a downstream creator can drain the trail on its own schedule.
pub struct PolicyTaskCreationOutbox {
    repository: VersionedJsonRepository<PolicyTaskCreationOutboxDocument>,
}

impl PolicyTaskCreationOutbox {
    #[must_use]
    pub fn new(mut root: PathBuf) -> Self {
        root.push("policy-task-creation-outbox-v1.json");
        Self {
            repository: VersionedJsonRepository::new(
                root,
                POLICY_TASK_CREATION_OUTBOX_SCHEMA_VERSION,
            ),
        }
    }

    /// Durably append a task-creation record, pruning expired leftovers first.
    ///
    /// # Errors
    /// Returns `CliError` if the durable outbox file cannot be read, parsed, or
    /// rewritten while appending the record.
    pub fn record(&self, record: TaskCreationRecord) -> Result<(), CliError> {
        self.record_at(record, Utc::now())
    }

    pub(crate) fn record_at(
        &self,
        record: TaskCreationRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            prune_expired(&mut document.records, now);
            document.records.push(record);
            Ok(Some(document))
        })?;
        Ok(())
    }

    /// All currently retained records, oldest first by insertion order.
    ///
    /// # Errors
    /// Returns `CliError` if the durable outbox file cannot be read or parsed.
    pub fn records(&self) -> Result<Vec<TaskCreationRecord>, CliError> {
        Ok(self.repository.load()?.unwrap_or_default().records)
    }
}

/// A task-board orchestration provider that records a task a workflow asked to
/// create. It proves the registry dispatches into the task-board domain and
/// gives a `task_board.create` step a real durable side effect.
pub struct TaskCreationPolicyProvider {
    root: PathBuf,
}

impl TaskCreationPolicyProvider {
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }
}

#[async_trait]
impl PolicyActionProvider for TaskCreationPolicyProvider {
    fn domain(&self) -> &'static str {
        TASK_CREATION_PROVIDER
    }

    async fn execute(
        &self,
        action: &PolicyActionDescriptor,
        ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, CliError> {
        let payload = task_creation_payload(action.payload.as_ref())?;
        let title = if payload.title.trim().is_empty() {
            "untitled".to_owned()
        } else {
            payload.title.trim().to_owned()
        };
        let body = payload
            .body
            .as_deref()
            .map(str::trim)
            .filter(|body| !body.is_empty())
            .map(str::to_owned);

        let outbox = PolicyTaskCreationOutbox::new(self.root.clone());
        outbox.record(TaskCreationRecord {
            title: title.clone(),
            body,
            workflow_id: ctx.workflow_id.clone(),
            subject_key: ctx.subject.key.clone(),
            recorded_at: utc_now(),
        })?;

        tracing::info!(
            workflow_id = %ctx.workflow_id,
            subject = %ctx.subject.key,
            title = %title,
            "policy workflow recorded task creation"
        );
        Ok(PolicyActionExecution {
            action_key: action.action_key.clone(),
        })
    }
}

fn task_creation_payload(
    payload: Option<&serde_json::Value>,
) -> Result<TaskCreationActionPayload, CliError> {
    match payload {
        None => Ok(TaskCreationActionPayload::default()),
        Some(payload) => serde_json::from_value(payload.clone()).map_err(|error| {
            CliErrorKind::invalid_transition(format!(
                "invalid task creation action payload: {error}"
            ))
            .into()
        }),
    }
}

fn prune_expired(records: &mut Vec<TaskCreationRecord>, now: DateTime<Utc>) {
    records.retain(|record| !record_is_expired(&record.recorded_at, now));
}

fn record_is_expired(recorded_at: &str, now: DateTime<Utc>) -> bool {
    DateTime::parse_from_rfc3339(recorded_at).is_ok_and(|recorded| {
        now.signed_duration_since(recorded.with_timezone(&Utc))
            .num_seconds()
            > TASK_CREATION_RETENTION_SECONDS
    })
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
    fn provider_domain_is_task_board() {
        let dir = tempdir().expect("tempdir");
        let provider = TaskCreationPolicyProvider::new(dir.path().to_path_buf());
        assert_eq!(provider.domain(), "task_board");
    }

    #[tokio::test]
    async fn execute_records_a_durable_task_creation() {
        let dir = tempdir().expect("tempdir");
        let provider = TaskCreationPolicyProvider::new(dir.path().to_path_buf());
        let action = PolicyActionDescriptor {
            provider: TASK_CREATION_PROVIDER.to_owned(),
            action_key: TASK_CREATION_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "title": "Follow up", "body": "check flaky" })),
        };
        let execution = provider
            .execute(&action, &execution_context())
            .await
            .expect("execute task creation");
        assert_eq!(execution.action_key, TASK_CREATION_ACTION_KEY);

        let outbox = PolicyTaskCreationOutbox::new(dir.path().to_path_buf());
        let records = outbox.records().expect("records");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].title, "Follow up");
        assert_eq!(records[0].body.as_deref(), Some("check flaky"));
        assert_eq!(records[0].subject_key, "owner/repo#1");
    }

    #[tokio::test]
    async fn registry_dispatches_task_creation_action_to_the_provider() {
        let dir = tempdir().expect("tempdir");
        let mut registry = PolicyProviderRegistry::default();
        registry.register(TaskCreationPolicyProvider::new(dir.path().to_path_buf()));
        let action = PolicyActionDescriptor {
            provider: TASK_CREATION_PROVIDER.to_owned(),
            action_key: TASK_CREATION_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "title": "Follow up" })),
        };
        let execution = registry
            .execute(&action, &execution_context())
            .await
            .expect("dispatch task creation");
        assert_eq!(execution.action_key, TASK_CREATION_ACTION_KEY);
    }
}
