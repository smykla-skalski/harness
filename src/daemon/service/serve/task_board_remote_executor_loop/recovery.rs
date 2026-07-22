use super::*;

pub(super) async fn prepare_recovery(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    action: RemoteWorkerAction,
    persisted_permit: Option<TaskBoardRemoteExecutorStartIoPermit>,
) -> Result<Option<PreparedRemoteWorker>, CliError> {
    if action != RemoteWorkerAction::Probe {
        let permit = persisted_permit.as_ref().ok_or_else(|| {
            concurrent("remote executor recovery has neither a run nor a Start I/O permit")
        })?;
        reconcile_persisted_start_without_run(db, record, permit).await?;
        return Ok(None);
    }
    let Some(session) = db.resolve_session(&identity.session_id).await? else {
        return Ok(None);
    };
    Ok(Some(PreparedRemoteWorker {
        workspace: session.state.worktree_path,
        action: PreparedRemoteWorkerAction::Probe(persisted_permit),
    }))
}
