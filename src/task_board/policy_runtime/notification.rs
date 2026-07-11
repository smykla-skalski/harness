#[cfg(test)]
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
#[cfg(test)]
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
#[cfg(test)]
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::workspace::utc_now;

use super::action_persistence::PolicyActionPersistence;
use super::models::PolicyActionDescriptor;
use super::providers::{PolicyActionExecution, PolicyActionProvider, PolicyExecutionContext};

/// Provider domain for cross-cutting notification dispatch.
pub const NOTIFICATION_PROVIDER: &str = "notification";
/// Action key that a compiled notification step dispatches to.
pub const NOTIFICATION_ACTION_KEY: &str = "notification.emit";

pub const POLICY_NOTIFICATION_OUTBOX_SCHEMA_VERSION: u32 = 1;

/// Records older than this are pruned on append so a notification trail that is
/// never delivered downstream cannot accumulate forever.
#[cfg(test)]
const NOTIFICATION_RETENTION_SECONDS: i64 = 3600;

#[derive(Debug, Default, Deserialize)]
struct NotificationActionPayload {
    #[serde(default)]
    channel: String,
    #[serde(default)]
    message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotificationRecord {
    pub channel: String,
    pub message: String,
    pub workflow_id: String,
    pub subject_key: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyNotificationOutboxDocument {
    pub schema_version: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub records: Vec<NotificationRecord>,
}

impl Default for PolicyNotificationOutboxDocument {
    fn default() -> Self {
        Self {
            schema_version: POLICY_NOTIFICATION_OUTBOX_SCHEMA_VERSION,
            records: Vec::new(),
        }
    }
}

/// A durable, append-only trail of notifications a policy workflow asked to
/// emit. Recording them durably means a notification survives a daemon restart
/// and a downstream sender can drain the trail on its own schedule.
#[cfg(test)]
pub struct PolicyNotificationOutbox {
    repository: VersionedJsonRepository<PolicyNotificationOutboxDocument>,
}

#[cfg(test)]
impl PolicyNotificationOutbox {
    #[must_use]
    pub fn new(mut root: PathBuf) -> Self {
        root.push("policy-notification-outbox-v1.json");
        Self {
            repository: VersionedJsonRepository::new(
                root,
                POLICY_NOTIFICATION_OUTBOX_SCHEMA_VERSION,
            ),
        }
    }

    /// Durably append a notification record, pruning expired leftovers first.
    ///
    /// # Errors
    /// Returns `CliError` if the durable outbox file cannot be read, parsed, or
    /// rewritten while appending the record.
    pub fn record(&self, record: NotificationRecord) -> Result<(), CliError> {
        self.record_at(record, Utc::now())
    }

    pub(crate) fn record_at(
        &self,
        record: NotificationRecord,
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
    pub fn records(&self) -> Result<Vec<NotificationRecord>, CliError> {
        Ok(self.repository.load()?.unwrap_or_default().records)
    }
}

/// A domain-agnostic orchestration provider that records a notification a
/// workflow asked to emit. It proves the registry dispatches beyond the reviews
/// and handoff domains and gives notification steps a real durable side effect.
pub struct NotificationPolicyProvider {
    persistence: PolicyActionPersistence,
}

impl NotificationPolicyProvider {
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
impl PolicyActionProvider for NotificationPolicyProvider {
    fn domain(&self) -> &'static str {
        NOTIFICATION_PROVIDER
    }

    async fn execute(
        &self,
        action: &PolicyActionDescriptor,
        ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, CliError> {
        let payload = notification_payload(action.payload.as_ref())?;
        let channel = nonempty_or(&payload.channel, "default");
        let message = nonempty_or(&payload.message, "(empty)");

        self.persistence
            .record_notification(NotificationRecord {
                channel: channel.to_owned(),
                message: message.to_owned(),
                workflow_id: ctx.workflow_id.clone(),
                subject_key: ctx.subject.key.clone(),
                recorded_at: utc_now(),
            })
            .await?;

        tracing::info!(
            workflow_id = %ctx.workflow_id,
            subject = %ctx.subject.key,
            channel,
            "policy workflow recorded notification"
        );
        Ok(PolicyActionExecution {
            action_key: action.action_key.clone(),
        })
    }
}

fn nonempty_or<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.trim().is_empty() {
        fallback
    } else {
        value.trim()
    }
}

fn notification_payload(
    payload: Option<&serde_json::Value>,
) -> Result<NotificationActionPayload, CliError> {
    match payload {
        None => Ok(NotificationActionPayload::default()),
        Some(payload) => serde_json::from_value(payload.clone()).map_err(|error| {
            CliErrorKind::invalid_transition(format!(
                "invalid notification action payload: {error}"
            ))
            .into()
        }),
    }
}

#[cfg(test)]
fn prune_expired(records: &mut Vec<NotificationRecord>, now: DateTime<Utc>) {
    records.retain(|record| !record_is_expired(&record.recorded_at, now));
}

#[cfg(test)]
fn record_is_expired(recorded_at: &str, now: DateTime<Utc>) -> bool {
    DateTime::parse_from_rfc3339(recorded_at).is_ok_and(|recorded| {
        now.signed_duration_since(recorded.with_timezone(&Utc))
            .num_seconds()
            > NOTIFICATION_RETENTION_SECONDS
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
    fn provider_domain_is_notification() {
        let dir = tempdir().expect("tempdir");
        let provider = NotificationPolicyProvider::new(dir.path().to_path_buf());
        assert_eq!(provider.domain(), "notification");
    }

    #[tokio::test]
    async fn execute_records_a_durable_notification() {
        let dir = tempdir().expect("tempdir");
        let provider = NotificationPolicyProvider::new(dir.path().to_path_buf());
        let action = PolicyActionDescriptor {
            provider: NOTIFICATION_PROVIDER.to_owned(),
            action_key: NOTIFICATION_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "channel": "ops", "message": "merged" })),
        };
        let execution = provider
            .execute(&action, &execution_context())
            .await
            .expect("execute notification");
        assert_eq!(execution.action_key, NOTIFICATION_ACTION_KEY);

        let outbox = PolicyNotificationOutbox::new(dir.path().to_path_buf());
        let records = outbox.records().expect("records");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].channel, "ops");
        assert_eq!(records[0].message, "merged");
        assert_eq!(records[0].subject_key, "owner/repo#1");
    }

    #[tokio::test]
    async fn registry_dispatches_notification_action_to_the_provider() {
        let dir = tempdir().expect("tempdir");
        let mut registry = PolicyProviderRegistry::default();
        registry.register(NotificationPolicyProvider::new(dir.path().to_path_buf()));
        let action = PolicyActionDescriptor {
            provider: NOTIFICATION_PROVIDER.to_owned(),
            action_key: NOTIFICATION_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "channel": "ops", "message": "hi" })),
        };
        let execution = registry
            .execute(&action, &execution_context())
            .await
            .expect("dispatch notification");
        assert_eq!(execution.action_key, NOTIFICATION_ACTION_KEY);
    }
}
