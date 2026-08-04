use crate::daemon::db_handle::{AsyncDaemonDbHandle, DaemonDbOwnedHandle};
use crate::daemon::index::ResolvedSession;
use crate::observe::types::Issue;
use harness_kernel::errors::CliError;

pub(crate) use harness_daemon_session_service::observe_actor_id;

pub(crate) fn apply_issue_tasks_to_db(
    db: &DaemonDbOwnedHandle,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    harness_daemon_session_service::apply_issue_tasks(db, resolved, actor_id, issues)
}

pub(crate) async fn apply_issue_tasks_to_async_db(
    async_db: &AsyncDaemonDbHandle,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    harness_daemon_session_service::apply_issue_tasks_async(async_db, resolved, actor_id, issues)
        .await
}

pub(crate) async fn apply_heuristic_gap_tasks_to_async_db(
    async_db: &AsyncDaemonDbHandle,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    harness_daemon_session_service::apply_heuristic_gap_tasks_async(
        async_db, resolved, actor_id, issues,
    )
    .await
}
