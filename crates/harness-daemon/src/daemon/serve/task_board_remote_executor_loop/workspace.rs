use std::path::{Path, PathBuf};

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

    pub(super) fn path(&self) -> &Path {
        &self.path
    }

    pub(super) fn workspace_id(&self) -> Option<&str> {
        self.workspace_id.as_deref()
    }
}
