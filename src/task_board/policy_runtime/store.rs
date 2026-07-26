use async_trait::async_trait;
use chrono::{DateTime, Utc};
use harness_kernel::errors::CliError;

use super::handoff_outbox::HandoffRecord;
use super::models::{PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun};
use super::notification::NotificationRecord;
use super::repository::BeginRunOutcome;
use super::task_creation::TaskCreationRecord;

/// Durable sink for the records a policy action emits.
///
/// The handoff path publishes its event as a second call rather than folding
/// both writes into one method, so the ordering the runtime relies on stays
/// visible here instead of moving into whatever backs the trait.
#[async_trait]
pub(crate) trait PolicyActionStore: Send + Sync {
    /// Append one handoff record.
    async fn record_handoff_at(
        &self,
        record: HandoffRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError>;

    /// Publish one workflow event.
    async fn publish_event_at(
        &self,
        event: PolicyWorkflowEvent,
        now: DateTime<Utc>,
    ) -> Result<(), CliError>;

    /// Append one notification record.
    async fn record_notification_at(
        &self,
        record: NotificationRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError>;

    /// Append one task-creation record.
    async fn record_task_creation_at(
        &self,
        record: TaskCreationRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError>;
}

/// Durable store for policy workflow run state.
#[async_trait]
pub(crate) trait PolicyRunStore: Send + Sync {
    /// Start a run, or report the live run that already covers its subject.
    async fn begin_run(
        &self,
        run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
        now: DateTime<Utc>,
    ) -> Result<BeginRunOutcome, CliError>;

    /// Claim a waiting run so exactly one caller resumes it.
    async fn claim_waiting_run(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError>;

    /// Persist the run's current state.
    async fn save_run(&self, run: &PolicyWorkflowRun) -> Result<(), CliError>;
}
