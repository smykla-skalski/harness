use super::{
    AckResult, CliError, CliErrorKind, HookAgent, Path, PathBuf, ResolvedSession, SessionLogEntry,
    SessionTransition, SignalAck, session_service, snapshot, utc_now, write_signal_ack,
};
use crate::agents::runtime::{runtime_for_name, signal::pending_dir};
use crate::daemon::db::{AsyncDaemonDb, ExpiredPendingSignalIndexRecord};
use crate::session::types::SessionState;

/// Re-sync a session from files into `SQLite` after a file-based mutation.
/// Silently ignores errors since the file write already succeeded and the
/// watch loop will eventually catch up.
pub(crate) fn sync_after_mutation(db: Option<&super::db::DaemonDb>, session_id: &str) {
    if let Some(db) = db {
        let _ = db.resync_session(session_id);
    }
}

pub(crate) fn record_signal_ack(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return session_service::record_signal_acknowledgment(
            session_id,
            agent_id,
            signal_id,
            result,
            project_dir,
        );
    };
    let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
        return session_service::record_signal_acknowledgment(
            session_id,
            agent_id,
            signal_id,
            result,
            project_dir,
        );
    };

    let already_logged = db.load_session_log(session_id)?.into_iter().any(|entry| {
        matches!(
            entry.transition,
            SessionTransition::SignalAcknowledged { signal_id: ref existing, .. }
                if existing == signal_id
        )
    });
    if already_logged {
        return Ok(());
    }

    let now = utc_now();
    let signal = session_service::load_signal_record_for_agent_from_state(
        &state,
        agent_id,
        signal_id,
        project_dir,
    )?;
    let result = signal.as_ref().map_or(result, |signal| {
        session_service::normalize_signal_ack_result(&signal.signal, result)
    });
    let mut started_task = None;

    if let Some(signal) = signal.as_ref() {
        started_task = session_service::apply_signal_ack_result(
            &mut state,
            agent_id,
            &signal.signal,
            result,
            &now,
        );
        session_service::refresh_session(&mut state, &now);
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
    }

    if let Some(task_id) = started_task.as_deref() {
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, agent_id),
            Some(agent_id),
            None,
        ))?;
    }

    db.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_signal_acknowledged(signal_id, agent_id, result),
        Some(agent_id),
        None,
    ))?;
    refresh_signal_index_for_db(db, session_id)?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(())
}

pub(crate) fn reconcile_expired_pending_signals_for_db(
    session_id: &str,
    db: &super::db::DaemonDb,
) -> Result<(), CliError> {
    let expired = db.load_expired_pending_signals(session_id)?;
    if expired.is_empty() {
        return Ok(());
    }

    let Some(state) = db.load_session_state_for_mutation(session_id)? else {
        return Ok(());
    };
    let Some(project_dir) = db.project_dir_for_session(session_id)? else {
        return Ok(());
    };
    let project_dir = PathBuf::from(project_dir);
    let context_root = session_service::signal_context_root(&project_dir);
    let mut needs_filesystem_fallback = false;

    for indexed_signal in expired {
        if !acknowledge_indexed_expired_signal(
            session_id,
            &project_dir,
            &context_root,
            &state,
            db,
            &indexed_signal,
        )? {
            needs_filesystem_fallback = true;
        }
    }

    if needs_filesystem_fallback {
        let expired =
            session_service::collect_expired_pending_signals_for_state(&state, &project_dir)?;
        for signal in expired {
            let ack = SignalAck {
                signal_id: signal.signal.signal_id.clone(),
                acknowledged_at: utc_now(),
                result: AckResult::Expired,
                agent: signal.signal_session_id.clone(),
                session_id: session_id.to_string(),
                details: Some("expired before agent acknowledged delivery".to_string()),
            };
            write_signal_ack(&signal.signal_dir, &ack)?;
            record_signal_ack(
                session_id,
                &signal.agent_id,
                &signal.signal.signal_id,
                AckResult::Expired,
                &project_dir,
                Some(db),
            )?;
        }
    }

    Ok(())
}

fn acknowledge_indexed_expired_signal(
    session_id: &str,
    project_dir: &Path,
    context_root: &Path,
    state: &SessionState,
    db: &super::db::DaemonDb,
    indexed_signal: &ExpiredPendingSignalIndexRecord,
) -> Result<bool, CliError> {
    let Some(agent) = state.agents.get(&indexed_signal.agent_id) else {
        return Ok(false);
    };
    let Some(runtime) = runtime_for_name(&indexed_signal.runtime) else {
        return Ok(false);
    };

    let Some((signal_session_id, signal_dir)) = session_service::signal_dirs_for_agent(
        runtime,
        session_id,
        agent.agent_session_id.as_deref(),
        context_root,
    )
    .into_iter()
    .find(|(_, signal_dir)| {
        pending_dir(signal_dir)
            .join(format!("{}.json", indexed_signal.signal.signal_id))
            .is_file()
    }) else {
        return Ok(false);
    };

    let ack = SignalAck {
        signal_id: indexed_signal.signal.signal_id.clone(),
        acknowledged_at: utc_now(),
        result: AckResult::Expired,
        agent: signal_session_id,
        session_id: session_id.to_string(),
        details: Some("expired before agent acknowledged delivery".to_string()),
    };
    write_signal_ack(&signal_dir, &ack)?;
    record_signal_ack(
        session_id,
        &indexed_signal.agent_id,
        &indexed_signal.signal.signal_id,
        AckResult::Expired,
        project_dir,
        Some(db),
    )?;
    Ok(true)
}

pub(crate) fn refresh_signal_index_for_db(
    db: &super::db::DaemonDb,
    session_id: &str,
) -> Result<(), CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    db.sync_signal_index(session_id, &signals)
}

pub(crate) fn append_leave_signal_logs_to_db(
    db: &super::db::DaemonDb,
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
    db: &super::db::DaemonDb,
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

pub(crate) fn resolve_hook_agent(runtime_name: &str) -> Option<HookAgent> {
    match runtime_name {
        "claude" => Some(HookAgent::Claude),
        "copilot" => Some(HookAgent::Copilot),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "vibe" => Some(HookAgent::Vibe),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

pub(crate) fn session_not_found(session_id: &str) -> CliError {
    CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
}

pub(crate) fn project_dir_for_db_session(
    db: &super::db::DaemonDb,
    session_id: &str,
) -> Result<PathBuf, CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    Ok(effective_project_dir(&resolved).to_path_buf())
}

pub(crate) fn write_task_start_signals(
    project_dir: &Path,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    let signals: Vec<_> = effects
        .iter()
        .filter_map(|effect| match effect {
            session_service::TaskDropEffect::Started(signal) => Some(signal.as_ref().clone()),
            session_service::TaskDropEffect::Queued { .. } => None,
        })
        .collect();
    session_service::write_prepared_task_start_signals(project_dir, &signals)
}

pub(crate) fn append_task_drop_effect_logs(
    db: &super::db::DaemonDb,
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

/// Return the original project directory when available, falling back to the
/// context root. This is safe because `project_context_dir` is idempotent
/// for paths already under the projects root.
pub(crate) fn effective_project_dir(resolved: &ResolvedSession) -> &Path {
    resolved
        .project
        .project_dir
        .as_deref()
        .unwrap_or(&resolved.project.context_root)
}
