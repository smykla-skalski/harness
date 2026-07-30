use std::path::{Path, PathBuf};
use std::time::Duration;

use harness_agents::runtime::AgentRuntime;
use harness_agents::runtime::signal::{Signal, SignalAck};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::service as session_service;
use harness_session::types::SessionLogEntry;
use harness_session::wire::{SessionDetail, SignalAckRequest, SignalSendRequest};
use harness_workspace::workspace::utc_now;
use tokio::task::spawn_blocking;
use tokio::time::{Instant as TokioInstant, sleep};

use crate::async_ops::{
    bump_session, record_signal_ack_direct_async, resolved_session_for_signal_mutation,
    runtime_for_agent,
};
use crate::persistence::{build_log_entry, effective_project_dir, pending_signal_record};
use crate::ports::{AsyncSignalStorage, SignalWake};
use crate::sync::{
    ACTIVE_SIGNAL_ACK_POLL_INTERVAL, ACTIVE_SIGNAL_ACK_TIMEOUT, ManagedSignalWake, SignalCoords,
    handled_active_signal_ack_wait_result, handled_active_signal_wake_result, managed_signal_wake,
    managed_tui_id_for_registration, warn_active_signal_ack_record_failure,
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
    fn coords(&self) -> SignalCoords<'_> {
        SignalCoords {
            session_id: self.session_id,
            agent_id: self.agent_id,
            signal: self.signal,
            runtime: self.runtime,
            project_dir: self.project_dir,
            signal_session_id: self.signal_session_id,
        }
    }
}

async fn persist_sent_signal_state(
    storage: &impl AsyncSignalStorage,
    session_id: &str,
    request: &SignalSendRequest,
    now: &str,
) -> Result<(String, Option<String>, Option<String>), CliError> {
    storage
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
                .and_then(managed_tui_id_for_registration)
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
    runtime: &'static dyn AgentRuntime,
    project_dir: &Path,
    signal_session_id: &str,
    signal_id: &str,
    timeout: Duration,
) -> Result<Option<SignalAck>, CliError> {
    let deadline = TokioInstant::now() + timeout;
    loop {
        if let Some(ack) = read_runtime_acknowledgments_async(
            runtime,
            project_dir.to_path_buf(),
            signal_session_id.to_string(),
            "send signal",
        )
        .await?
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
    storage: &impl AsyncSignalStorage,
) -> Result<PreparedAsyncSignalDelivery, CliError> {
    let resolved = resolved_session_for_signal_mutation(storage, session_id).await?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let now = utc_now();
    let (runtime_name, target_agent_session_id, target_tui_id) =
        persist_sent_signal_state(storage, session_id, request, &now).await?;
    storage.sync_file_state(session_id).await?;
    let runtime = runtime_for_agent(&runtime_name)?;
    let signal = build_runtime_signal(request, session_id, &request.agent_id, &now);
    let signal_session_id = target_agent_session_id.unwrap_or_else(|| session_id.to_string());
    write_runtime_signal_async(
        runtime,
        project_dir.clone(),
        signal_session_id.clone(),
        signal.clone(),
        "send signal",
    )
    .await?;
    storage
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
    managed_wake: Option<ManagedSignalWake<'_>>,
    storage: &impl AsyncSignalStorage,
) -> Result<bool, CliError> {
    let Some(managed_wake) = managed_wake else {
        return Ok(false);
    };
    let ack_timeout = managed_wake
        .transport
        .ack_timeout_override()
        .unwrap_or(ACTIVE_SIGNAL_ACK_TIMEOUT);
    let woke_tui = {
        let wake_coords = delivery.coords();
        let Some(woke_tui) = handled_active_signal_wake_result(
            &wake_coords,
            managed_wake.transport.prompt(
                managed_wake.managed_id,
                &crate::sync::build_active_signal_prompt(delivery.signal),
            ),
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
        ack_timeout,
    )
    .await;
    let ack = {
        let ack_coords = delivery.coords();
        let Some(ack) = handled_active_signal_ack_wait_result(&ack_coords, ack_result, ack_timeout)
        else {
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
        storage,
    )
    .await;
    match result {
        Ok(()) => Ok(true),
        Err(error) => {
            let record_coords = delivery.coords();
            warn_active_signal_ack_record_failure(&record_coords, &error);
            Ok(false)
        }
    }
}

async fn finalize_signal_send(
    session_id: &str,
    storage: &impl AsyncSignalStorage,
    agent_id: &str,
    runtime_name: &str,
    signal: &Signal,
    actively_delivered: bool,
) -> Result<(), CliError> {
    if !actively_delivered {
        storage
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
    bump_session(storage, session_id).await
}

/// Send a signal while persisting the canonical async DB snapshot.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, signal delivery
/// setup fails, or canonical persistence fails.
pub async fn send_signal_async(
    session_id: &str,
    request: &SignalSendRequest,
    storage: &impl AsyncSignalStorage,
    wake: Option<&dyn SignalWake>,
) -> Result<SessionDetail, CliError> {
    let prepared = prepare_signal_send(session_id, request, storage).await?;
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
        managed_signal_wake(prepared.target_tui_id.as_deref(), wake),
        storage,
    )
    .await?;
    finalize_signal_send(
        session_id,
        storage,
        &request.agent_id,
        &prepared.runtime_name,
        &prepared.signal,
        actively_delivered,
    )
    .await?;
    storage.session_detail(session_id).await
}

async fn write_runtime_signal_async(
    runtime: &'static dyn AgentRuntime,
    project_dir: PathBuf,
    signal_session_id: String,
    signal: Signal,
    operation: &'static str,
) -> Result<(), CliError> {
    spawn_blocking(move || {
        runtime
            .write_signal(&project_dir, &signal_session_id, &signal)
            .map(|_| ())
    })
    .await
    .unwrap_or_else(|error| {
        Err(
            CliErrorKind::workflow_io(format!("{operation} signal write worker failed: {error}"))
                .into(),
        )
    })
}

async fn read_runtime_acknowledgments_async(
    runtime: &'static dyn AgentRuntime,
    project_dir: PathBuf,
    signal_session_id: String,
    operation: &'static str,
) -> Result<Vec<SignalAck>, CliError> {
    spawn_blocking(move || runtime.read_acknowledgments(&project_dir, &signal_session_id))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "{operation} acknowledgment scan worker failed: {error}"
            ))
            .into())
        })
}
