use std::path::{Path, PathBuf};

use crate::agents::runtime::AgentRuntime;
use crate::agents::runtime::signal::{Signal, SignalAck};
use tokio::time::{Instant as TokioInstant, sleep};

use super::signals::{
    agent_tui_id_for_registration, handled_active_signal_ack_wait_result,
    handled_active_signal_wake_result, managed_tui_wake, wake_tui_for_signal,
    warn_active_signal_ack_record_failure,
};
use super::signals_async::{
    bump_session, record_signal_ack_direct_async, resolved_session_for_signal_mutation,
    runtime_for_agent,
};
use super::{
    ACTIVE_SIGNAL_ACK_POLL_INTERVAL, ACTIVE_SIGNAL_ACK_TIMEOUT, ActiveSignalDelivery,
    AgentTuiManagerHandle, CliError, ManagedTuiWake, SessionDetail, SessionLogEntry,
    SignalAckRequest, SignalSendRequest, build_log_entry, effective_project_dir,
    pending_signal_record, session_detail_from_async_daemon_db, session_service, utc_now,
};

struct PreparedAsyncSignalDelivery {
    project_dir: PathBuf,
    runtime: &'static dyn AgentRuntime,
    runtime_name: String,
    signal: Signal,
    signal_session_id: String,
    target_tui_id: Option<String>,
}

struct AsyncActiveSignalDelivery<'a> {
    session_id: &'a str,
    agent_id: &'a str,
    signal: &'a Signal,
    runtime: &'static dyn AgentRuntime,
    project_dir: &'a Path,
    signal_session_id: &'a str,
}

impl AsyncActiveSignalDelivery<'_> {
    fn active_signal_delivery(&self) -> ActiveSignalDelivery<'_> {
        ActiveSignalDelivery {
            session_id: self.session_id,
            agent_id: self.agent_id,
            signal: self.signal,
            runtime: self.runtime,
            project_dir: self.project_dir,
            signal_session_id: self.signal_session_id,
            db: None,
        }
    }
}

async fn persist_sent_signal_state(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    request: &SignalSendRequest,
    now: &str,
) -> Result<(String, Option<String>, Option<String>), CliError> {
    async_db
        .update_session_state_immediate(session_id, |state| {
            let (runtime_name, target_agent_session_id) = session_service::apply_send_signal_state(
                state,
                &request.agent_id,
                &request.actor,
                now,
            )?;
            let target_tui_id = state
                .agents
                .get(&request.agent_id)
                .and_then(agent_tui_id_for_registration)
                .map(ToString::to_string);
            Ok((runtime_name, target_agent_session_id, target_tui_id))
        })
        .await
}

fn build_runtime_signal(
    request: &SignalSendRequest,
    session_id: &str,
    agent_id: &str,
    now: &str,
) -> Signal {
    session_service::build_signal(
        &request.actor,
        &request.command,
        &request.message,
        request.action_hint.as_deref(),
        session_id,
        agent_id,
        now,
    )
}

fn sent_signal_log_entry(
    session_id: &str,
    actor_id: &str,
    signal_id: &str,
    agent_id: &str,
    command: &str,
) -> SessionLogEntry {
    build_log_entry(
        session_id,
        session_service::log_signal_sent(signal_id, agent_id, command),
        Some(actor_id),
        None,
    )
}

async fn wait_for_signal_ack_async(
    runtime: &dyn AgentRuntime,
    project_dir: &Path,
    signal_session_id: &str,
    signal_id: &str,
) -> Result<Option<SignalAck>, CliError> {
    let deadline = TokioInstant::now() + ACTIVE_SIGNAL_ACK_TIMEOUT;
    loop {
        if let Some(ack) = runtime
            .read_acknowledgments(project_dir, signal_session_id)?
            .into_iter()
            .find(|ack| ack.signal_id == signal_id)
        {
            return Ok(Some(ack));
        }
        if TokioInstant::now() >= deadline {
            return Ok(None);
        }
        sleep(ACTIVE_SIGNAL_ACK_POLL_INTERVAL).await;
    }
}

async fn prepare_signal_send(
    session_id: &str,
    request: &SignalSendRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<PreparedAsyncSignalDelivery, CliError> {
    let resolved = resolved_session_for_signal_mutation(async_db, session_id).await?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let now = utc_now();
    let (runtime_name, target_agent_session_id, target_tui_id) =
        persist_sent_signal_state(async_db, session_id, request, &now).await?;
    let runtime = runtime_for_agent(&runtime_name)?;
    let signal = build_runtime_signal(request, session_id, &request.agent_id, &now);
    let signal_session_id = target_agent_session_id.unwrap_or_else(|| session_id.to_string());
    runtime.write_signal(&project_dir, &signal_session_id, &signal)?;
    async_db
        .append_log_entry(&sent_signal_log_entry(
            session_id,
            &request.actor,
            &signal.signal_id,
            &request.agent_id,
            &request.command,
        ))
        .await?;
    Ok(PreparedAsyncSignalDelivery {
        project_dir,
        runtime,
        runtime_name,
        signal,
        signal_session_id,
        target_tui_id,
    })
}

async fn attempt_active_signal_delivery_async(
    delivery: AsyncActiveSignalDelivery<'_>,
    managed_tui: Option<ManagedTuiWake<'_>>,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<bool, CliError> {
    let Some(managed_tui) = managed_tui else {
        return Ok(false);
    };
    let woke_tui = {
        let wake_delivery = delivery.active_signal_delivery();
        let Some(woke_tui) = handled_active_signal_wake_result(
            &wake_delivery,
            wake_tui_for_signal(&managed_tui, delivery.signal),
        ) else {
            return Ok(false);
        };
        woke_tui
    };
    if !woke_tui {
        return Ok(false);
    }

    let ack_result = wait_for_signal_ack_async(
        delivery.runtime,
        delivery.project_dir,
        delivery.signal_session_id,
        &delivery.signal.signal_id,
    )
    .await;
    let ack = {
        let ack_delivery = delivery.active_signal_delivery();
        let Some(ack) = handled_active_signal_ack_wait_result(&ack_delivery, ack_result) else {
            return Ok(false);
        };
        ack
    };

    let result = record_signal_ack_direct_async(
        delivery.session_id,
        &SignalAckRequest {
            agent_id: delivery.agent_id.to_string(),
            signal_id: delivery.signal.signal_id.clone(),
            result: ack.result,
            project_dir: delivery.project_dir.display().to_string(),
        },
        async_db,
    )
    .await;
    match result {
        Ok(()) => Ok(true),
        Err(error) => {
            let record_delivery = delivery.active_signal_delivery();
            warn_active_signal_ack_record_failure(&record_delivery, &error);
            Ok(false)
        }
    }
}

async fn finalize_signal_send(
    session_id: &str,
    async_db: &super::db::AsyncDaemonDb,
    agent_id: &str,
    runtime_name: &str,
    signal: &Signal,
    actively_delivered: bool,
) -> Result<(), CliError> {
    if !actively_delivered {
        async_db
            .merge_signal_records(
                session_id,
                &[pending_signal_record(
                    session_id,
                    runtime_name,
                    agent_id,
                    signal,
                )],
            )
            .await?;
    }
    bump_session(async_db, session_id).await
}

/// Send a signal while persisting the canonical async DB snapshot.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, signal delivery
/// setup fails, or canonical persistence fails.
pub(crate) async fn send_signal_async(
    session_id: &str,
    request: &SignalSendRequest,
    async_db: &super::db::AsyncDaemonDb,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
) -> Result<SessionDetail, CliError> {
    let prepared = prepare_signal_send(session_id, request, async_db).await?;
    let delivery = AsyncActiveSignalDelivery {
        session_id,
        agent_id: &request.agent_id,
        signal: &prepared.signal,
        runtime: prepared.runtime,
        project_dir: &prepared.project_dir,
        signal_session_id: &prepared.signal_session_id,
    };
    let actively_delivered = attempt_active_signal_delivery_async(
        delivery,
        managed_tui_wake(prepared.target_tui_id.as_deref(), agent_tui_manager),
        async_db,
    )
    .await?;
    finalize_signal_send(
        session_id,
        async_db,
        &request.agent_id,
        &prepared.runtime_name,
        &prepared.signal,
        actively_delivered,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}
