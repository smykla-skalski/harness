use async_trait::async_trait;

use crate::daemon::db::{AsyncDaemonDb, db_error};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalCreateOutcome, ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeState, TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{
    ExternalProvider, ExternalRef, ExternalSyncField, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateFinalizeResult, TaskBoardExternalCreateIntent,
    TaskBoardExternalCreateStore, TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict,
    TaskBoardSyncStore,
};

#[async_trait]
impl TaskBoardExternalCreateStore for AsyncDaemonDb {
    async fn begin_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        self.begin_task_board_external_create_intent(item_id, provider, scope_id, provider_target)
            .await
    }

    async fn record_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        self.record_task_board_external_create_outcome(intent, outcome, provider_baseline)
            .await
    }

    async fn finalize_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        self.finalize_task_board_external_create_intent(intent)
            .await
    }

    async fn list_created_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        self.list_created_task_board_external_create_intents().await
    }

    async fn list_in_flight_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        self.list_in_flight_task_board_external_create_intents(provider)
            .await
    }

    async fn external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        self.task_board_external_create_intent_by_create_key(provider, create_key)
            .await
    }

    async fn list_pending_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        self.list_pending_task_board_external_create_follow_ups(provider)
            .await
    }
}

#[async_trait]
impl TaskBoardSyncStore for AsyncDaemonDb {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        self.list_task_board_items(status).await
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        self.list_task_board_items_including_deleted().await
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        self.create_task_board_item(item)
            .await
            .map(|mutation| mutation.item)
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        let item_id = expected_item.id.clone();
        self.update_task_board_item(&item_id, |item| {
            if item != expected_item {
                return Err(CliErrorKind::concurrent_modification(format!(
                    "task-board item '{item_id}' changed during external sync"
                ))
                .into());
            }
            apply_patch(item, patch);
            Ok(true)
        })
        .await?
        .map(|mutation| mutation.item)
        .ok_or_else(|| db_error("Task Board sync update produced no mutation"))
    }

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        self.task_board_item_snapshot(item_id)
            .await
            .map(|snapshot| TaskBoardSyncItemSnapshot::new(snapshot.item, snapshot.item_revision))
    }

    async fn provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.task_board_provider_scope_state(provider, scope_id)
            .await
    }

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        self.begin_task_board_provider_scope_attempt(provider, scope_id, now)
            .await
    }

    async fn renew_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError> {
        self.renew_task_board_provider_scope_attempt(attempt, now)
            .await
    }

    async fn complete_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError> {
        self.complete_task_board_provider_scope_success(attempt, base_revision, completed_at)
            .await
    }

    async fn complete_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.complete_task_board_provider_scope_failure(attempt, completed_at)
            .await
    }

    async fn replace_open_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        self.replace_open_task_board_sync_conflicts(
            item_id,
            provider,
            external_ref,
            item_revision,
            conflicts,
        )
        .await
    }

    async fn supersede_open_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        self.supersede_open_task_board_sync_conflicts(
            item_id,
            provider,
            external_ref,
            item_revision,
            resolved_fields,
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;
    use crate::task_board::{
        ExternalCreateOutcome, ExternalRefProvider, ExternalRefSyncState, ExternalSyncField,
        ExternalTaskRef, TaskBoardConflictState, TaskBoardExternalCreateBegin,
        TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateIntent,
    };

    #[tokio::test]
    async fn external_sync_update_rejects_a_concurrent_local_edit() {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("open database");
        let created = db
            .create_task_board_item(TaskBoardItem::new(
                "task-concurrent-sync".into(),
                "Original title".into(),
                "Original body".into(),
                "2026-07-11T12:00:00Z".into(),
            ))
            .await
            .expect("create item")
            .item;
        db.update_task_board_item(&created.id, |item| {
            item.body = "Concurrent local edit".into();
            Ok(true)
        })
        .await
        .expect("local edit");

        let error = <AsyncDaemonDb as TaskBoardSyncStore>::update_item(
            &db,
            &created,
            TaskBoardItemPatch {
                title: Some("Remote title".into()),
                ..TaskBoardItemPatch::default()
            },
        )
        .await
        .expect_err("stale sync snapshot must be rejected");
        let current = db.task_board_item(&created.id).await.expect("current item");

        assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
        assert_eq!(current.title, "Original title");
        assert_eq!(current.body, "Concurrent local edit");
    }

    #[tokio::test]
    async fn external_create_store_delegates_the_durable_intent_lifecycle() {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("open database");
        db.create_task_board_item(TaskBoardItem::new(
            "task-create-store".into(),
            "Create title".into(),
            "Create body".into(),
            "2026-07-16T15:00:00Z".into(),
        ))
        .await
        .expect("create item");

        let started =
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::begin_external_create_intent(
                &db,
                "task-create-store",
                ExternalProvider::Todoist,
                "todoist:scope",
                "todoist-project",
            )
            .await
            .expect("begin create");
        let TaskBoardExternalCreateBegin::Started(intent) = started else {
            panic!("expected a newly started create intent");
        };
        assert_eq!(
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::
                list_in_flight_external_create_intents(&db, ExternalProvider::Todoist)
                .await
                .expect("list in-flight"),
            vec![intent.clone()]
        );
        assert_eq!(
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::external_create_intent_by_create_key(
                &db,
                ExternalProvider::Todoist,
                &intent.create_key,
            )
            .await
            .expect("lookup intent"),
            Some(intent.clone())
        );

        let (outcome, baseline) = create_evidence(&intent);
        let created =
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::record_external_create_outcome(
                &db, &intent, &outcome, &baseline,
            )
            .await
            .expect("record create outcome");
        assert_eq!(
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::list_created_external_create_intents(
                &db
            )
            .await
            .expect("list created"),
            vec![created.clone()]
        );
        let finalized =
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::finalize_external_create_intent(
                &db, &created,
            )
            .await
            .expect("finalize create");

        assert_eq!(
            finalized.disposition,
            TaskBoardExternalCreateFinalizeDisposition::Attached
        );
        assert_eq!(
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::external_create_intent_by_create_key(
                &db,
                ExternalProvider::Todoist,
                &intent.create_key,
            )
            .await
            .expect("lookup attached intent"),
            Some(finalized.intent.clone())
        );
        assert_eq!(
            <AsyncDaemonDb as TaskBoardExternalCreateStore>::list_pending_external_create_follow_ups(
                &db,
                Some(ExternalProvider::Todoist),
            )
            .await
            .expect("list pending attached receipts"),
            vec![finalized.intent]
        );
    }

    #[tokio::test]
    async fn sync_store_delegates_field_scoped_conflict_supersession() {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("open database");
        db.create_task_board_item(TaskBoardItem::new(
            "task-conflict-store".into(),
            "Conflict title".into(),
            String::new(),
            "2026-07-16T15:00:00Z".into(),
        ))
        .await
        .expect("create item");
        db.replace_open_task_board_sync_conflicts(
            "task-conflict-store",
            ExternalProvider::Todoist,
            "todoist-task",
            1,
            &[
                conflict("conflict-title", "title"),
                conflict("conflict-future", "future_field"),
            ],
        )
        .await
        .expect("record conflicts");

        <AsyncDaemonDb as TaskBoardSyncStore>::supersede_open_sync_conflicts(
            &db,
            "task-conflict-store",
            ExternalProvider::Todoist,
            "todoist-task",
            1,
            &[ExternalSyncField::Title],
        )
        .await
        .expect("supersede title conflict");

        let open = db
            .open_task_board_sync_conflicts()
            .await
            .expect("open conflicts");
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].field, "future_field");
    }

    fn create_evidence(
        intent: &TaskBoardExternalCreateIntent,
    ) -> (ExternalCreateOutcome, crate::task_board::ExternalRef) {
        let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "todoist-task")
            .with_url("https://example.invalid/tasks/todoist-task");
        let outcome = ExternalCreateOutcome {
            reference: reference.clone(),
            provider_revision: Some("provider-revision".into()),
            provider_project_id: Some("todoist-project".into()),
        };
        let mut baseline = reference.into_core_ref();
        baseline.sync_state = Some(ExternalRefSyncState {
            title: Some(intent.snapshot.title.clone()),
            body: Some(intent.snapshot.body.clone()),
            status: Some(TaskBoardStatus::Backlog),
            project_id: Some("todoist-project".into()),
            updated_at: Some("provider-revision".into()),
            synced_at: Some("2026-07-16T15:01:00Z".into()),
        });
        (outcome, baseline)
    }

    fn conflict(conflict_id: &str, field: &str) -> TaskBoardSyncConflict {
        TaskBoardSyncConflict {
            conflict_id: conflict_id.into(),
            item_id: "task-conflict-store".into(),
            provider: ExternalRefProvider::Todoist,
            external_ref: "todoist-task".into(),
            field: field.into(),
            base_value: serde_json::json!("base"),
            local_value: serde_json::json!("local"),
            remote_value: serde_json::json!("remote"),
            item_revision: 1,
            provider_revision: Some("provider-revision".into()),
            state: TaskBoardConflictState::Open,
        }
    }
}
