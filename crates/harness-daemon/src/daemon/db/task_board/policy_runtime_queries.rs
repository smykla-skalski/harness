//! The policy-runtime area's own interface onto [`AsyncDaemonDb`]: the
//! generic event inbox, handoff/notification/task-creation outboxes, and
//! workflow-run store that the daemon's review-policy engine
//! (`service::reviews`) reads and writes.
//!
//! This code lives under `db/task_board` because its schema was modeled
//! after task-board's own storage conventions when it was built, not because
//! it persists task-board data: it depends on no other task-board area beyond
//! the shared change-tracking bump every write in the seam already uses, and
//! nothing in task-board's own feature set calls it back. Its real consumer
//! is `service::reviews`, both directly (the query and mutation methods
//! below) and through the narrower [`PolicyActionStore`](crate::task_board::policy_runtime::store::PolicyActionStore)
//! and [`PolicyRunStore`](crate::task_board::policy_runtime::store::PolicyRunStore)
//! traits that `crate::daemon::policy_runtime_store` already adapts
//! `AsyncDaemonDb` to. That one-directional, task-board-independent coupling
//! is why this interface's natural home is conceptually closer to
//! `service::reviews` than to task-board's own seam; relocating the physical
//! files there is a separate pass, so this trait stays where its queries
//! already live.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block here can never move into a crate
//! `task_board` doesn't share with `db`. A trait `task_board` itself declares
//! has no such problem: Rust's orphan rule only requires one of the trait or
//! the implementing type to be local, and the trait is. That is what lets
//! this area's queries move into their own crate (or relocate next to
//! `service::reviews`) later without dragging every other area's inherent
//! impls along for the ride, the same way
//! [`super::provider_queries::ProviderQueries`] does for provider-sync.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.
//!
//! Unlike the dispatch and admission-ledger cluster, this area needed no
//! second, transaction-scoped extension trait: its private helpers
//! (`load_events`, `write_runs`, and so on) are reached by nothing outside
//! `policy_queues.rs` and `policy_runs.rs` today, confirmed by grep across
//! every direction, so there is no internal fan-in for a second boundary to
//! close.

use chrono::{DateTime, Utc};

use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::policy_runtime::handoff_outbox::HandoffRecord;
use crate::task_board::policy_runtime::models::{
    PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun,
};
use crate::task_board::policy_runtime::notification::NotificationRecord;
use crate::task_board::policy_runtime::repository::BeginRunOutcome;
use crate::task_board::policy_runtime::task_creation::TaskCreationRecord;

pub(crate) trait PolicyRuntimeQueries: Send + Sync {
    async fn publish_policy_event_at(
        &self,
        event: PolicyWorkflowEvent,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError>;

    async fn pending_policy_events(&self) -> Result<Vec<PolicyWorkflowEvent>, CliError>;

    async fn remove_delivered_policy_events_at(
        &self,
        delivered: &[PolicyWorkflowEvent],
        now: DateTime<Utc>,
    ) -> Result<i64, CliError>;

    async fn record_policy_handoff_at(
        &self,
        record: HandoffRecord,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError>;

    async fn policy_handoff_records(&self) -> Result<Vec<HandoffRecord>, CliError>;

    async fn record_policy_notification_at(
        &self,
        record: NotificationRecord,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError>;

    async fn policy_notification_records(&self) -> Result<Vec<NotificationRecord>, CliError>;

    async fn record_policy_task_creation_at(
        &self,
        record: TaskCreationRecord,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError>;

    async fn policy_task_creation_records(&self) -> Result<Vec<TaskCreationRecord>, CliError>;

    async fn save_policy_workflow_run(&self, run: &PolicyWorkflowRun) -> Result<i64, CliError>;

    async fn begin_policy_workflow_run(
        &self,
        run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
        now: DateTime<Utc>,
    ) -> Result<BeginRunOutcome, CliError>;

    async fn claim_waiting_policy_run(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError>;

    async fn policy_workflow_runs(&self) -> Result<Vec<PolicyWorkflowRun>, CliError>;

    async fn policy_run_by_id(&self, run_id: &str) -> Result<Option<PolicyWorkflowRun>, CliError>;

    async fn policy_runs_for_subject(
        &self,
        workflow_id: &str,
        subject_key: &str,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError>;

    async fn active_policy_runs_for_subject(
        &self,
        workflow_id: &str,
        subject_key: &str,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError>;

    async fn policy_run_ids_ready_for_event(
        &self,
        event: &PolicyWorkflowEvent,
    ) -> Result<Vec<String>, CliError>;

    async fn policy_runs_ready_for_timer(
        &self,
        now: DateTime<Utc>,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// area's query logic, kept in the file the query has always lived in
/// (`policy_queues.rs`, `policy_runs.rs`) so this file stays a pure interface
/// plus wiring, not a dumping ground.
impl PolicyRuntimeQueries for AsyncDaemonDb {
    async fn publish_policy_event_at(
        &self,
        event: PolicyWorkflowEvent,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError> {
        super::policy_queues::publish_policy_event_at(self, event, now).await
    }

    async fn pending_policy_events(&self) -> Result<Vec<PolicyWorkflowEvent>, CliError> {
        super::policy_queues::pending_policy_events(self).await
    }

    async fn remove_delivered_policy_events_at(
        &self,
        delivered: &[PolicyWorkflowEvent],
        now: DateTime<Utc>,
    ) -> Result<i64, CliError> {
        super::policy_queues::remove_delivered_policy_events_at(self, delivered, now).await
    }

    async fn record_policy_handoff_at(
        &self,
        record: HandoffRecord,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError> {
        super::policy_queues::record_policy_handoff_at(self, record, now).await
    }

    async fn policy_handoff_records(&self) -> Result<Vec<HandoffRecord>, CliError> {
        super::policy_queues::policy_handoff_records(self).await
    }

    async fn record_policy_notification_at(
        &self,
        record: NotificationRecord,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError> {
        super::policy_queues::record_policy_notification_at(self, record, now).await
    }

    async fn policy_notification_records(&self) -> Result<Vec<NotificationRecord>, CliError> {
        super::policy_queues::policy_notification_records(self).await
    }

    async fn record_policy_task_creation_at(
        &self,
        record: TaskCreationRecord,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError> {
        super::policy_queues::record_policy_task_creation_at(self, record, now).await
    }

    async fn policy_task_creation_records(&self) -> Result<Vec<TaskCreationRecord>, CliError> {
        super::policy_queues::policy_task_creation_records(self).await
    }

    async fn save_policy_workflow_run(&self, run: &PolicyWorkflowRun) -> Result<i64, CliError> {
        super::policy_runs::save_policy_workflow_run(self, run).await
    }

    async fn begin_policy_workflow_run(
        &self,
        run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
        now: DateTime<Utc>,
    ) -> Result<BeginRunOutcome, CliError> {
        super::policy_runs::begin_policy_workflow_run(self, run, trigger, now).await
    }

    async fn claim_waiting_policy_run(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        super::policy_runs::claim_waiting_policy_run(self, run_id, trigger).await
    }

    async fn policy_workflow_runs(&self) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        super::policy_runs::policy_workflow_runs(self).await
    }

    async fn policy_run_by_id(&self, run_id: &str) -> Result<Option<PolicyWorkflowRun>, CliError> {
        super::policy_runs::policy_run_by_id(self, run_id).await
    }

    async fn policy_runs_for_subject(
        &self,
        workflow_id: &str,
        subject_key: &str,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        super::policy_runs::policy_runs_for_subject(self, workflow_id, subject_key).await
    }

    async fn active_policy_runs_for_subject(
        &self,
        workflow_id: &str,
        subject_key: &str,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        super::policy_runs::active_policy_runs_for_subject(self, workflow_id, subject_key).await
    }

    async fn policy_run_ids_ready_for_event(
        &self,
        event: &PolicyWorkflowEvent,
    ) -> Result<Vec<String>, CliError> {
        super::policy_runs::policy_run_ids_ready_for_event(self, event).await
    }

    async fn policy_runs_ready_for_timer(
        &self,
        now: DateTime<Utc>,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        super::policy_runs::policy_runs_ready_for_timer(self, now).await
    }
}
