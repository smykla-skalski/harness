use crate::session::storage as session_storage;
use crate::session::types::SessionState;
use crate::workspace::harness_data_root;
use crate::workspace::layout::{SessionLayout, sessions_root as workspace_sessions_root};
use crate::workspace::worktree::WorktreeController;

/// Destroy the on-disk artifacts for a session: deregister the active-session
/// marker and tear down its git worktree. Failures are logged and swallowed so
/// the caller's DB cleanup can always proceed.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(super) fn destroy_session_artifacts(state: &SessionState) {
    let sessions_root = workspace_sessions_root(&harness_data_root());
    let layout = SessionLayout {
        sessions_root,
        project_name: state.project_name.clone(),
        session_id: state.session_id.clone(),
    };
    if let Err(error) = session_storage::deregister_active(&layout) {
        tracing::warn!(%error, session_id = %state.session_id, "deregister active failed");
    }
    if !state.origin_path.as_os_str().is_empty()
        && let Err(error) = WorktreeController::destroy(&state.origin_path, &layout)
    {
        tracing::warn!(%error, session_id = %state.session_id, "worktree destroy failed");
    }
}
