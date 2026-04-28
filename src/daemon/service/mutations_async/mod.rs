use crate::daemon::index::ResolvedSession;

use super::{
    AgentTuiManagerHandle, CliError, SessionTransition, build_log_entry, effective_project_dir,
    session_not_found, session_service, snapshot, sync_file_state_for_resolved,
    task_drop_effect_signal_records, try_wake_started_workers, write_task_start_signals,
};

mod agents;
mod sessions;
mod tasks;

pub(crate) use agents::{change_role_async, remove_agent_async};
pub(crate) use sessions::{end_session_async, transfer_leader_async};
pub(crate) use tasks::{
    assign_task_async, checkpoint_task_async, create_task_async, drop_task_async,
    update_task_async, update_task_queue_policy_async,
};

async fn resolved_session_for_mutation(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<ResolvedSession, CliError> {
    async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

async fn bump_session(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<(), CliError> {
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await
}

async fn refresh_signal_index_for_resolved(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
) -> Result<(), CliError> {
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    async_db
        .sync_signal_index(&resolved.state.session_id, &signals)
        .await
}

async fn append_log(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    transition: SessionTransition,
    actor_id: &str,
) -> Result<(), CliError> {
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            transition,
            Some(actor_id),
            None,
        ))
        .await
}

async fn append_task_drop_effect_logs_async(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    actor_id: &str,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    for effect in effects {
        let transition = match effect {
            session_service::TaskDropEffect::Started(signal) => session_service::log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            session_service::TaskDropEffect::Queued { task_id, agent_id } => {
                session_service::log_task_queued(task_id, agent_id)
            }
        };
        append_log(async_db, session_id, transition, actor_id).await?;
    }
    Ok(())
}

async fn append_leave_signal_logs_async(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    actor_id: &str,
    signals: &[session_service::LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        let transition = session_service::log_signal_sent(
            &signal.signal.signal_id,
            &signal.agent_id,
            &signal.signal.command,
        );
        append_log(async_db, session_id, transition, actor_id).await?;
    }
    Ok(())
}

async fn persist_task_signal_effects(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
    session_id: &str,
    actor_id: &str,
    effects: &[session_service::TaskDropEffect],
    extra_transition: Option<SessionTransition>,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
) -> Result<(), CliError> {
    let project_dir = effective_project_dir(resolved).to_path_buf();
    sync_file_state_for_resolved(resolved)?;
    write_task_start_signals(&project_dir, effects)?;
    if let Some(transition) = extra_transition {
        append_log(async_db, session_id, transition, actor_id).await?;
    }
    append_task_drop_effect_logs_async(async_db, session_id, actor_id, effects).await?;
    async_db
        .merge_signal_records(
            session_id,
            &task_drop_effect_signal_records(session_id, effects),
        )
        .await?;
    try_wake_started_workers(
        &resolved.state,
        effects,
        session_id,
        &project_dir,
        None,
        agent_tui_manager,
    );
    bump_session(async_db, session_id).await
}

async fn persist_leave_signal_mutation(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
    session_id: &str,
    actor_id: &str,
    leave_signals: &[session_service::LeaveSignalRecord],
    transition: SessionTransition,
) -> Result<(), CliError> {
    sync_file_state_for_resolved(resolved)?;
    append_leave_signal_logs_async(async_db, session_id, actor_id, leave_signals).await?;
    append_log(async_db, session_id, transition, actor_id).await?;
    refresh_signal_index_for_resolved(async_db, resolved).await?;
    bump_session(async_db, session_id).await
}
