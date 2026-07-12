use async_trait::async_trait;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

use super::TaskBoardSyncStore;

#[async_trait]
impl TaskBoardSyncStore for TaskBoardStore {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let board = self.clone();
        tokio::task::spawn_blocking(move || board.list(status))
            .await
            .map_err(|error| sync_join_error("list items", error))?
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        let board = self.clone();
        tokio::task::spawn_blocking(move || board.list_including_deleted())
            .await
            .map_err(|error| sync_join_error("list tombstones", error))?
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        let board = self.clone();
        tokio::task::spawn_blocking(move || {
            let title = item.title.clone();
            let body = item.body.clone();
            board.create(&title, &body, item)
        })
        .await
        .map_err(|error| sync_join_error("create item", error))?
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        let board = self.clone();
        let expected_item = expected_item.clone();
        tokio::task::spawn_blocking(move || {
            let item_id = expected_item.id.clone();
            board
                .update_if(&item_id, |current| {
                    (current == &expected_item).then_some(patch)
                })?
                .ok_or_else(|| {
                    CliError::from(CliErrorKind::concurrent_modification(format!(
                        "task-board item '{item_id}' changed during external sync"
                    )))
                })
        })
        .await
        .map_err(|error| sync_join_error("update item", error))?
    }
}

fn sync_join_error(operation: &str, error: tokio::task::JoinError) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board external sync {operation} worker failed: {error}"
    ))
    .into()
}
