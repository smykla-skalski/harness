use crate::session::storage as session_storage;
use crate::session::types::SessionState;
use crate::workspace::harness_data_root;
use crate::workspace::layout::{SessionLayout, sessions_root as workspace_sessions_root};
use crate::workspace::worktree::WorktreeController;

/// Destroy the on-disk artifacts for a session: deregister the active-session
/// marker and tear down its linked checkout. Failures are logged and swallowed so
/// the caller's DB cleanup can always proceed.
///
/// For externally-rooted sessions (`external_origin` is `Some`), the worktree
/// was not created by this daemon, so only deregistration runs; the worktree is
/// left intact.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(super) fn destroy_session_artifacts(state: &SessionState) {
    let layout = build_layout(state);
    if let Err(error) = session_storage::deregister_active(&layout) {
        tracing::warn!(%error, session_id = %state.session_id, "deregister active failed");
    }
    if state.external_origin.is_some() {
        tracing::warn!(session_id = %state.session_id, "external session; skipping worktree destroy");
        return;
    }
    if !state.origin_path.as_os_str().is_empty()
        && let Err(error) = WorktreeController::destroy(&state.origin_path, &layout)
    {
        tracing::warn!(%error, session_id = %state.session_id, "worktree destroy failed");
    }
}

fn build_layout(state: &SessionState) -> SessionLayout {
    if let Some(session_root) = state.external_origin.as_ref()
        && let Some(project_dir) = session_root.parent()
        && let Some(sessions_root) = project_dir.parent()
        && let Some(project_name) = project_dir.file_name()
    {
        return SessionLayout {
            sessions_root: sessions_root.to_path_buf(),
            project_name: project_name.to_string_lossy().into_owned(),
            session_id: state.session_id.clone(),
        };
    }
    let sessions_root = workspace_sessions_root(&harness_data_root());
    SessionLayout {
        sessions_root,
        project_name: state.project_name.clone(),
        session_id: state.session_id.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use crate::session::types::{SessionMetrics, SessionState, SessionStatus};

    fn state_with_external_origin(origin: PathBuf) -> SessionState {
        SessionState {
            schema_version: crate::session::types::CURRENT_VERSION,
            state_version: 0,
            session_id: "abc12345".into(),
            project_name: "demo".into(),
            worktree_path: PathBuf::new(),
            shared_path: PathBuf::new(),
            origin_path: PathBuf::new(),
            branch_ref: String::new(),
            title: String::new(),
            context: String::new(),
            status: SessionStatus::Active,
            policy: Default::default(),
            created_at: "2026-04-20T00:00:00Z".into(),
            updated_at: "2026-04-20T00:00:00Z".into(),
            agents: BTreeMap::new(),
            tasks: BTreeMap::new(),
            leader_id: None,
            archived_at: None,
            last_activity_at: None,
            observe_id: None,
            pending_leader_transfer: None,
            external_origin: Some(origin),
            adopted_at: Some("2026-04-20T00:00:00Z".into()),
            metrics: SessionMetrics::default(),
        }
    }

    #[test]
    fn build_layout_uses_external_origin_when_set() {
        let origin = PathBuf::from("/tmp/external/demo/abc12345");
        let state = state_with_external_origin(origin.clone());
        let layout = build_layout(&state);
        assert_eq!(layout.sessions_root, PathBuf::from("/tmp/external"));
        assert_eq!(layout.project_name, "demo");
        assert_eq!(layout.session_id, "abc12345");
    }

    #[test]
    fn build_layout_falls_back_to_data_root_when_no_external() {
        let mut state = state_with_external_origin(PathBuf::new());
        state.external_origin = None;
        let layout = build_layout(&state);
        assert_eq!(layout.project_name, "demo");
        assert_eq!(layout.session_id, "abc12345");
        // sessions_root is the daemon data root's sessions dir; we just care it
        // ends with "sessions".
        assert_eq!(
            layout.sessions_root.file_name().and_then(|v| v.to_str()),
            Some("sessions")
        );
    }
}
