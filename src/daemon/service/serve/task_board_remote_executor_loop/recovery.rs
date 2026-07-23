use super::{
    AsyncDaemonDb, CliError, PreparedRemoteWorker, PreparedRemoteWorkerAction, RemoteWorkerAction,
    RemoteWorkerIdentity, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartIoPermit,
    concurrent, executor_start_authority, reconcile_persisted_start_without_run, utc_now,
};

pub(super) async fn abandon_predecessor_claim(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    daemon_epoch: &str,
) -> Result<bool, CliError> {
    if record.claimed_host_instance_id.as_deref() == Some(daemon_epoch)
        || executor_start_authority(record)?.is_some()
    {
        return Ok(false);
    }
    let _ = db
        .abandon_task_board_remote_executor_claim_after_restart(
            &record.assignment_id,
            identity,
            daemon_epoch,
            &utc_now(),
        )
        .await?;
    Ok(true)
}

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
