use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{ExternalProvider, TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict};

#[derive(Debug, Clone)]
pub(crate) struct TaskBoardSyncItemSnapshot {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
}

impl TaskBoardSyncItemSnapshot {
    pub(crate) const fn new(item: TaskBoardItem, item_revision: i64) -> Self {
        Self {
            item,
            item_revision,
        }
    }
}

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

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError>;

    async fn provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError>;

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError>;

    async fn renew_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError>;

    async fn complete_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError>;

    async fn complete_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError>;

    async fn replace_open_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError>;
}
