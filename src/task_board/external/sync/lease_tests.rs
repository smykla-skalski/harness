use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;
use crate::task_board::external::{
    ExternalCreateLease, ExternalCreateProbe, ExternalCreateRecoveryClient, ExternalCreateRequest,
    ExternalProviderScopeIdentity,
};
use crate::task_board::{
    ExternalCreateOutcome, ExternalRefSyncState, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateIntentState, TaskBoardExternalCreateStore,
};

mod client;
mod coordinator;
mod marker;
mod support;
use client::DurableCreateClient;
use support::DurableCreateStore;

#[tokio::test]
async fn stale_lease_stops_before_remote_create() {
    let calls = Arc::new(AtomicUsize::new(0));
    let store = DurableCreateStore::stale_lease(unlinked_item("task-lease"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::GitHub,
        "acme/widgets",
        Arc::clone(&calls),
    ))];

    let batch =
        sync_external_tasks_scoped(&store, push_options(ExternalProvider::GitHub), &clients)
            .await
            .expect("stale lease must retain scope evidence");

    assert_eq!(store.failure_completions.load(Ordering::SeqCst), 1);
    let evidence = batch.scope_outcomes[0]
        .error
        .as_deref()
        .expect("stale lease failure evidence");
    assert_eq!(
        batch.scope_outcomes[0].error_code.as_deref(),
        Some("WORKFLOW_CONCURRENT")
    );
    assert!(evidence.contains("provider scope lease was replaced"));
    assert!(evidence.contains("stale provider scope cannot be finalized"));
    let error = batch
        .into_completed()
        .expect_err("stale lease must stop the scope");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert!(
        error
            .details()
            .is_some_and(|details| details.contains("stale provider scope cannot be finalized"))
    );
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn capability_lease_io_failure_remains_a_terminal_local_error() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut item = unlinked_item("task-lease-io");
    item.project_id = Some("provider-project".into());
    let store = DurableCreateStore::io_lease_failure(item);
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(&calls),
    ))];

    let batch =
        sync_external_tasks_scoped(&store, push_options(ExternalProvider::Todoist), &clients)
            .await
            .expect("local lease failure must retain scope evidence");

    assert!(batch.terminal_error.is_some());
    assert!(batch.first_provider_failure.is_none());
    assert_eq!(
        batch.scope_outcomes[0].error_code.as_deref(),
        Some("WORKFLOW_IO")
    );
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert!(matches!(
        store.intent().state,
        TaskBoardExternalCreateIntentState::InFlight
    ));
}

#[tokio::test]
async fn coordinator_cancellation_releases_scope_without_failure_backoff() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut item = unlinked_item("task-coordinator-cancel");
    item.project_id = Some("provider-project".into());
    let store = DurableCreateStore::coordinator_cancelled(item);
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(&calls),
    ))];

    let batch =
        sync_external_tasks_scoped(&store, push_options(ExternalProvider::Todoist), &clients)
            .await
            .expect("coordinator cancellation retains scope evidence");

    assert!(batch.terminal_error.is_some());
    assert!(batch.first_provider_failure.is_none());
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(store.failure_completions.load(Ordering::SeqCst), 0);
    assert_eq!(store.neutral_releases.load(Ordering::SeqCst), 1);
    assert_eq!(store.coordinator_checks.load(Ordering::SeqCst), 1);
    assert_eq!(
        *store.fence_order.lock().expect("fence order"),
        vec!["provider", "provider", "coordinator"]
    );
    assert!(matches!(
        store.intent().state,
        TaskBoardExternalCreateIntentState::InFlight
    ));
}

#[tokio::test]
async fn create_then_close_uses_the_finalized_current_item_status() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut item = unlinked_item("task-finalized-done");
    item.project_id = Some("provider-project".into());
    let store = DurableCreateStore::done_during_finalize(item);
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(&calls),
    ))];

    let operations = sync_external_tasks(&store, push_options(ExternalProvider::Todoist), &clients)
        .await
        .expect("finalized Done item");

    assert_eq!(operations.len(), 2);
    assert!(operations[0].applied);
    assert_eq!(
        operations[1].unsupported_fields,
        vec![ExternalSyncField::Status]
    );
}

#[tokio::test]
async fn conflict_cleanup_failure_keeps_exact_create_evidence_unattached() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut item = unlinked_item("task-create-cleanup");
    item.project_id = Some("provider-project".into());
    let store = DurableCreateStore::cleanup_failure(item);
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(&calls),
    ))];

    let batch =
        sync_external_tasks_scoped(&store, push_options(ExternalProvider::Todoist), &clients)
            .await
            .expect("cleanup failure must retain exact create evidence");

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(batch.operations.is_empty());
    assert!(batch.external_create_follow_ups.is_empty());
    assert!(matches!(
        store.intent().state,
        TaskBoardExternalCreateIntentState::Created(_)
    ));
    let error = batch
        .into_completed()
        .expect_err("conflict cleanup must remain visible");
    assert!(error.message().contains("conflict cleanup failed"));
}

#[tokio::test]
async fn remote_create_with_failed_local_link_retains_created_reference_evidence() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut item = unlinked_item("task-create-cas");
    item.project_id = Some("provider-project".into());
    let store = DurableCreateStore::finalize_failure(item);
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(&calls),
    ))];

    let batch =
        sync_external_tasks_scoped(&store, push_options(ExternalProvider::Todoist), &clients)
            .await
            .expect("finalization failure must retain recorded provider evidence");

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(batch.operations.is_empty());
    let intent = store.intent();
    let TaskBoardExternalCreateIntentState::Created(evidence) = intent.state else {
        panic!("provider evidence must remain Created");
    };
    assert_eq!(evidence.outcome.reference.external_id, "remote-created");
    assert_eq!(
        evidence.outcome.provider_revision.as_deref(),
        Some("provider-revision-1")
    );
    assert_eq!(
        evidence.outcome.provider_project_id.as_deref(),
        Some("provider-project")
    );
    let baseline = evidence
        .provider_baseline
        .sync_state
        .as_ref()
        .expect("exact provider baseline");
    assert_eq!(baseline.title.as_deref(), Some("Task"));
    assert_eq!(baseline.body.as_deref(), Some(""));
    assert_eq!(baseline.status, Some(TaskBoardStatus::Backlog));
    assert_eq!(baseline.project_id.as_deref(), Some("provider-project"));
    assert_eq!(baseline.updated_at.as_deref(), Some("provider-revision-1"));
    let error = batch
        .into_completed()
        .expect_err("local finalization failure must stop the scope");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}

#[tokio::test]
async fn attached_receipt_causes_no_preflight_scan_or_repeat_create_operation() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut item = unlinked_item("task-attached-retry");
    item.project_id = Some("provider-project".into());
    let store = successful_store(item);
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(&calls),
    ))];
    let first = sync_external_tasks(&store, push_options(ExternalProvider::Todoist), &clients)
        .await
        .expect("attach provider create");
    assert_eq!(first.len(), 1);
    assert!(first[0].applied);
    let before_record = store.record_calls.load(Ordering::SeqCst);
    let before_finalize = store.finalize_calls.load(Ordering::SeqCst);
    let before_cleanup = store.supersede_calls.load(Ordering::SeqCst);
    let work = super::create_recovery::load_external_create_recovery_work(
        &store,
        Some(ExternalProvider::Todoist),
    )
    .await
    .expect("load active recovery");
    assert!(work.is_empty());
    assert_eq!(store.tombstone_list_calls.load(Ordering::SeqCst), 0);
    let prepared = super::create_recovery::prepare_external_create_recovery(
        &store,
        pull_options(ExternalProvider::Todoist),
        work,
    )
    .await
    .expect("prepare active recovery");
    assert!(prepared.is_empty());

    let second = sync_external_tasks(&store, push_options(ExternalProvider::Todoist), &clients)
        .await
        .expect("repeat sync");

    assert!(second.is_empty());
    assert_eq!(store.record_calls.load(Ordering::SeqCst), before_record);
    assert_eq!(store.finalize_calls.load(Ordering::SeqCst), before_finalize);
    assert_eq!(store.supersede_calls.load(Ordering::SeqCst), before_cleanup);
}

#[tokio::test]
async fn created_preflight_suppresses_pull_base_revision_persistence() {
    let mut item = unlinked_item("task-recovery-base");
    item.project_id = Some("provider-project".into());
    let store = successful_store(item);
    let client = RecoveryPullClient;
    let scope = ExternalProviderScopeIdentity::for_client(&client);
    let started = store
        .begin_external_create_intent(
            "task-recovery-base",
            ExternalProvider::Todoist,
            scope.scope_id(),
            "provider-project",
        )
        .await
        .expect("begin create");
    let TaskBoardExternalCreateBegin::Started(intent) = started else {
        panic!("expected started intent");
    };
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-created");
    let outcome = ExternalCreateOutcome {
        reference: reference.clone(),
        provider_revision: Some("provider-revision-1".into()),
        provider_project_id: Some("provider-project".into()),
    };
    let mut baseline = reference.into_core_ref();
    baseline.sync_state = Some(ExternalRefSyncState {
        title: Some("Task".into()),
        body: Some(String::new()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: Some("provider-project".into()),
        updated_at: Some("provider-revision-1".into()),
        synced_at: Some("2026-07-16T10:00:00Z".into()),
    });
    store
        .record_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect("record create outcome");
    let work = super::create_recovery::load_external_create_recovery_work(
        &store,
        Some(ExternalProvider::Todoist),
    )
    .await
    .expect("load created receipt");
    let prepared = super::create_recovery::prepare_external_create_recovery(
        &store,
        pull_options(ExternalProvider::Todoist),
        work,
    )
    .await
    .expect("prepare created receipt");
    let recovery_clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(RecoveryPullClient)];
    let plan = super::create_recovery::assign_external_create_recovery(prepared, &recovery_clients)
        .expect("assign created receipt");

    sync_external_tasks_scoped_with_recovery(
        &store,
        pull_options(ExternalProvider::Todoist),
        &recovery_clients,
        plan,
    )
    .await
    .expect("pull after Created recovery");

    assert_eq!(
        *store.success_base_revision.lock().expect("base revision"),
        Some(None)
    );
}

struct RecoveryPullClient;

#[async_trait::async_trait]
impl ExternalSyncClient for RecoveryPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn external_create_recovery(&self) -> Option<&dyn ExternalCreateRecoveryClient> {
        Some(self)
    }

    fn scope_id(&self) -> String {
        "provider-project".into()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(vec![ExternalTask {
            reference: ExternalTaskRef::new(ExternalProvider::Todoist, "remote-created"),
            title: "Task".into(),
            body: String::new(),
            status: TaskBoardStatus::Backlog,
            project_id: Some("provider-project".into()),
            updated_at: Some("provider-revision-1".into()),
            ..ExternalTask::default()
        }])
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only recovery test")
    }
}

#[async_trait::async_trait]
impl ExternalCreateRecoveryClient for RecoveryPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn supports_target(&self, provider_target: &str) -> bool {
        provider_target == "provider-project"
    }

    async fn create_started(
        &self,
        _request: &ExternalCreateRequest,
        _lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalTask, CliError> {
        unreachable!("attached recovery test")
    }

    async fn recover_existing(
        &self,
        _request: &ExternalCreateRequest,
        _lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalCreateProbe, CliError> {
        unreachable!("attached recovery test")
    }
}

fn unlinked_item(id: &str) -> TaskBoardItem {
    TaskBoardItem::new(
        id.into(),
        "Task".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    )
}

fn successful_store(item: TaskBoardItem) -> DurableCreateStore {
    DurableCreateStore::new(item, None, None, None, None, None)
}

fn push_options(provider: ExternalProvider) -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(provider),
        direction: ExternalSyncDirection::Push,
        dry_run: false,
        ..ExternalSyncOptions::default()
    }
}

fn pull_options(provider: ExternalProvider) -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(provider),
        direction: ExternalSyncDirection::Pull,
        dry_run: false,
        ..ExternalSyncOptions::default()
    }
}
