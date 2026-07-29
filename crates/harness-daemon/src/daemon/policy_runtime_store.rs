use async_trait::async_trait;
use chrono::{DateTime, Utc};
use harness_kernel::errors::CliError;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::policy_runtime::handoff_outbox::HandoffRecord;
use crate::task_board::policy_runtime::models::{
    PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun,
};
use crate::task_board::policy_runtime::notification::NotificationRecord;
use crate::task_board::policy_runtime::repository::BeginRunOutcome;
use crate::task_board::policy_runtime::store::{PolicyActionStore, PolicyRunStore};
use crate::task_board::policy_runtime::task_creation::TaskCreationRecord;

#[cfg(test)]
mod tests;

// The row ids these writes return identify the queue rows, which nothing on the
// policy-runtime side reads, so they stop here rather than widening the trait.
#[async_trait]
impl PolicyActionStore for AsyncDaemonDb {
    async fn record_handoff_at(
        &self,
        record: HandoffRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        self.record_policy_handoff_at(record, now).await.map(|_| ())
    }

    async fn publish_event_at(
        &self,
        event: PolicyWorkflowEvent,
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        self.publish_policy_event_at(event, now).await.map(|_| ())
    }

    async fn record_notification_at(
        &self,
        record: NotificationRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        self.record_policy_notification_at(record, now)
            .await
            .map(|_| ())
    }

    async fn record_task_creation_at(
        &self,
        record: TaskCreationRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        self.record_policy_task_creation_at(record, now)
            .await
            .map(|_| ())
    }
}

#[async_trait]
impl PolicyRunStore for AsyncDaemonDb {
    async fn begin_run(
        &self,
        run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
        now: DateTime<Utc>,
    ) -> Result<BeginRunOutcome, CliError> {
        self.begin_policy_workflow_run(run, trigger, now).await
    }

    async fn claim_waiting_run(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        self.claim_waiting_policy_run(run_id, trigger).await
    }

    async fn save_run(&self, run: &PolicyWorkflowRun) -> Result<(), CliError> {
        self.save_policy_workflow_run(run).await.map(|_| ())
    }
}
