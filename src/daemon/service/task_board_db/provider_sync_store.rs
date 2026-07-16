use async_trait::async_trait;

use crate::daemon::db::{AsyncDaemonDb, db_error};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::ExternalProviderScopeState;
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{
    ExternalProvider, TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict, TaskBoardSyncStore,
};

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

    async fn item_revision(&self, item_id: &str) -> Result<i64, CliError> {
        self.task_board_item_snapshot(item_id)
            .await
            .map(|snapshot| snapshot.item_revision)
    }

    async fn provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.task_board_provider_scope_state(provider, scope_id)
            .await
    }

    async fn record_provider_scope_success(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        base_revision: Option<&str>,
    ) -> Result<(), CliError> {
        self.record_task_board_provider_scope_success(provider, scope_id, base_revision)
            .await
    }

    async fn record_provider_scope_failure(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.record_task_board_provider_scope_failure(provider, scope_id)
            .await
    }

    async fn replace_open_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        self.replace_open_task_board_sync_conflicts(item_id, provider, external_ref, conflicts)
            .await
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

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
}
