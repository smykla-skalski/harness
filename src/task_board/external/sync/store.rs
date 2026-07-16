use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::external::ExternalProviderScopeState;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{ExternalProvider, TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict};

#[async_trait]
pub(crate) trait TaskBoardSyncStore: Send + Sync {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError>;
    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError>;
    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError>;
    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError>;

    async fn item_revision(&self, _item_id: &str) -> Result<i64, CliError> {
        Ok(0)
    }

    async fn provider_scope_state(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        Ok(ExternalProviderScopeState::default())
    }

    async fn record_provider_scope_success(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
        _base_revision: Option<&str>,
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn record_provider_scope_failure(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        Ok(ExternalProviderScopeState::default())
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        Ok(())
    }
}
