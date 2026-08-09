use std::path::{Path, PathBuf};

use harness_kernel::errors::{CliError, CliErrorKind};
use tokio::task::spawn_blocking;

use crate::daemon::db::task_board::TaskBoardRemoteExecutorStartReceipt;

/// Executor-local owner of a remote worker. `workspace_id` is absent only for
/// a persisted legacy offer whose checkout is still backed by a Session.
#[derive(Debug)]
pub(super) struct PreparedRemoteWorkspace {
    path: PathBuf,
    workspace_id: Option<String>,
}

impl std::ops::Deref for PreparedRemoteWorkspace {
    type Target = Path;

    fn deref(&self) -> &Self::Target {
        self.path()
    }
}

impl PreparedRemoteWorkspace {
    pub(super) fn legacy(path: PathBuf) -> Self {
        Self {
            path,
            workspace_id: None,
        }
    }

    pub(super) fn owned(path: PathBuf, workspace_id: String) -> Self {
        Self {
            path,
            workspace_id: Some(workspace_id),
        }
    }

    pub(super) fn from_start_receipt(receipt: &TaskBoardRemoteExecutorStartReceipt) -> Self {
        receipt.workspace_id.as_ref().map_or_else(
            || Self::legacy(PathBuf::from(&receipt.project_dir)),
            |workspace_id| Self::owned(PathBuf::from(&receipt.project_dir), workspace_id.clone()),
        )
    }

    pub(super) async fn require_repository(&self) -> Result<(), CliError> {
        let worktree = self.path.clone();
        spawn_blocking(move || super::source::validate_remote_worktree_head(&worktree, "", false))
            .await
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("join terminal workspace check: {error}"))
            })?
    }

    pub(super) fn path(&self) -> &Path {
        &self.path
    }

    pub(super) fn workspace_id(&self) -> Option<&str> {
        self.workspace_id.as_deref()
    }
}
