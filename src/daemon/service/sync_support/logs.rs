use crate::daemon::db::DaemonDb;

use super::{
    AsyncDaemonDb, CliError, SessionLogEntry, SessionTransition, session_service, utc_now,
};

pub(crate) fn append_leave_signal_logs_to_db(
    db: &DaemonDb,
    session_id: &str,
    actor_id: &str,
    signals: &[session_service::LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            Some(actor_id),
            None,
        ))?;
    }
    Ok(())
}

pub(crate) fn append_transfer_logs_to_db(
    db: &DaemonDb,
    session_id: &str,
    actor_id: &str,
    plan: &session_service::LeaderTransferPlan,
) -> Result<(), CliError> {
    if let Some(ref request) = plan.pending_request {
        db.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: request.current_leader_id.clone(),
                to: request.new_leader_id.clone(),
            },
            Some(actor_id),
            request.reason.as_deref(),
        ))?;
        return Ok(());
    }
    if let Some(ref outcome) = plan.outcome {
        if outcome.log_request_before_transfer {
            db.append_log_entry(&build_log_entry(
                session_id,
                SessionTransition::LeaderTransferRequested {
                    from: outcome.old_leader.clone(),
                    to: outcome.new_leader_id.clone(),
                },
                Some(actor_id),
                outcome.reason.as_deref(),
            ))?;
        }
        if let Some(ref confirmed_by) = outcome.confirmed_by {
            db.append_log_entry(&build_log_entry(
                session_id,
                SessionTransition::LeaderTransferConfirmed {
                    from: outcome.old_leader.clone(),
                    to: outcome.new_leader_id.clone(),
                    confirmed_by: confirmed_by.clone(),
                },
                Some(confirmed_by),
                outcome.reason.as_deref(),
            ))?;
        }
        db.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LeaderTransferred {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
            },
            Some(actor_id),
            outcome.reason.as_deref(),
        ))?;
    }
    Ok(())
}

pub(crate) async fn append_transfer_logs_to_async_db(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    actor_id: &str,
    plan: &session_service::LeaderTransferPlan,
) -> Result<(), CliError> {
    if let Some(ref request) = plan.pending_request {
        append_async_transfer_log(
            async_db,
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: request.current_leader_id.clone(),
                to: request.new_leader_id.clone(),
            },
            Some(actor_id),
            request.reason.as_deref(),
        )
        .await?;
        return Ok(());
    }
    if let Some(ref outcome) = plan.outcome {
        append_async_transfer_outcome_logs(async_db, session_id, actor_id, outcome).await?;
    }
    Ok(())
}

async fn append_async_transfer_outcome_logs(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    actor_id: &str,
    outcome: &session_service::LeaderTransferOutcome,
) -> Result<(), CliError> {
    if outcome.log_request_before_transfer {
        append_async_transfer_log(
            async_db,
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
            },
            Some(actor_id),
            outcome.reason.as_deref(),
        )
        .await?;
    }
    if let Some(ref confirmed_by) = outcome.confirmed_by {
        append_async_transfer_log(
            async_db,
            session_id,
            SessionTransition::LeaderTransferConfirmed {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
                confirmed_by: confirmed_by.clone(),
            },
            Some(confirmed_by),
            outcome.reason.as_deref(),
        )
        .await?;
    }
    append_async_transfer_log(
        async_db,
        session_id,
        SessionTransition::LeaderTransferred {
            from: outcome.old_leader.clone(),
            to: outcome.new_leader_id.clone(),
        },
        Some(actor_id),
        outcome.reason.as_deref(),
    )
    .await
}

async fn append_async_transfer_log(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> Result<(), CliError> {
    async_db
        .append_log_entry(&build_log_entry(session_id, transition, actor_id, reason))
        .await
}

pub(crate) fn append_task_drop_effect_logs(
    db: &DaemonDb,
    session_id: &str,
    actor_id: &str,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    for effect in effects {
        match effect {
            session_service::TaskDropEffect::Started(signal) => {
                db.append_log_entry(&build_log_entry(
                    session_id,
                    session_service::log_signal_sent(
                        &signal.signal.signal_id,
                        &signal.agent_id,
                        &signal.signal.command,
                    ),
                    Some(actor_id),
                    None,
                ))?;
            }
            session_service::TaskDropEffect::Queued { task_id, agent_id } => {
                db.append_log_entry(&build_log_entry(
                    session_id,
                    session_service::log_task_queued(task_id, agent_id),
                    Some(actor_id),
                    None,
                ))?;
            }
        }
    }
    Ok(())
}

pub(crate) fn build_log_entry(
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> SessionLogEntry {
    SessionLogEntry {
        sequence: 0,
        recorded_at: utc_now(),
        session_id: session_id.to_string(),
        transition,
        actor_id: actor_id.map(ToString::to_string),
        reason: reason.map(ToString::to_string),
    }
}
