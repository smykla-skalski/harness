use std::path::Path;
use std::time::Duration;

use harness_agents::runtime;
use harness_agents::runtime::signal::{AckResult, Signal, SignalAck};
use harness_daemon_session_service::{SignalStorage, SignalWake, attempt_active_signal_delivery};
use harness_kernel::errors::CliError;
use harness_session::service as session_service;
use harness_session::types::{SessionLogEntry, SessionSignalRecord, SessionState};
use tokio::sync::broadcast;

use super::super::agent_acp::AcpWakePrompt;
use super::super::agent_tui::AgentTuiManagerHandle;
use super::super::db::DaemonDb;
use super::super::protocol::{
    CodexSteerRequest, SessionDetail, SignalCancelRequest, SignalSendRequest, StreamEvent,
};
use super::wake_route::{WakeDispatch, WakeRoute, log_wake_attempt, wake_route_for_registration};
use super::{ManagedTuiWake, SignalCoords, broadcast_session_snapshot, sessions};

pub(crate) use harness_daemon_session_service::build_active_signal_prompt;
pub(crate) use harness_daemon_session_service::managed_tui_id_for_registration;

impl SignalStorage for DaemonDb {
    fn load_session_state_for_mutation(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionState>, CliError> {
        Self::load_session_state_for_mutation(self, session_id)
    }

    fn load_session_state(&self, session_id: &str) -> Result<Option<SessionState>, CliError> {
        Self::load_session_state(self, session_id)
    }

    fn load_session_log(&self, session_id: &str) -> Result<Vec<SessionLogEntry>, CliError> {
        Self::load_session_log(self, session_id)
    }

    fn project_id_for_session(&self, session_id: &str) -> Result<Option<String>, CliError> {
        Self::project_id_for_session(self, session_id)
    }

    fn project_dir_for_session(&self, session_id: &str) -> Result<Option<String>, CliError> {
        Self::project_dir_for_session(self, session_id)
    }

    fn save_session_state(&self, project_id: &str, state: &SessionState) -> Result<(), CliError> {
        Self::save_session_state(self, project_id, state)
    }

    fn resolve_session(
        &self,
        session_id: &str,
    ) -> Result<Option<harness_session::index::ResolvedSession>, CliError> {
        Self::resolve_session(self, session_id)
    }

    fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        Self::load_signals(self, session_id)
    }

    fn merge_signal_records(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        Self::merge_signal_records(self, session_id, records)
    }

    fn sync_signal_index(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        Self::sync_signal_index(self, session_id, records)
    }

    fn append_log_entry(&self, entry: &SessionLogEntry) -> Result<(), CliError> {
        Self::append_log_entry(self, entry)
    }

    fn bump_change(&self, scope: &str) -> Result<(), CliError> {
        Self::bump_change(self, scope)
    }

    fn session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError> {
        sessions::session_detail_from_daemon_db(session_id, self)
    }
}

impl SignalWake for AgentTuiManagerHandle {
    fn ack_timeout_override(&self) -> Option<Duration> {
        Self::ack_timeout_override(self)
    }

    fn prompt(&self, managed_id: &str, prompt: &str) -> Result<bool, CliError> {
        self.prompt_tui(managed_id, prompt)
    }
}

pub(crate) fn wake_tui_for_signal(
    managed_tui: &ManagedTuiWake<'_>,
    signal: &Signal,
) -> Result<bool, CliError> {
    let prompt = build_active_signal_prompt(signal);
    managed_tui.manager.prompt_tui(managed_tui.tui_id, &prompt)
}

pub(crate) fn handled_active_signal_wake_result(
    coords: &SignalCoords<'_>,
    wake_result: Result<bool, CliError>,
) -> Option<bool> {
    match wake_result {
        Ok(woke_tui) => Some(woke_tui),
        Err(error) => {
            warn_active_signal_wake_failure(coords, &error);
            None
        }
    }
}

pub(crate) fn handled_active_signal_ack_wait_result(
    coords: &SignalCoords<'_>,
    ack_result: Result<Option<SignalAck>, CliError>,
    ack_timeout: Duration,
) -> Option<SignalAck> {
    match ack_result {
        Ok(Some(ack)) => Some(ack),
        Ok(None) => {
            warn_active_signal_delivery_timeout(
                coords.session_id,
                coords.agent_id,
                &coords.signal.signal_id,
                ack_timeout,
            );
            None
        }
        Err(error) => {
            warn_active_signal_ack_wait_failure(coords, &error);
            None
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
fn warn_active_signal_wake_failure(coords: &SignalCoords<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = coords.session_id,
        agent_id = coords.agent_id,
        signal_id = %coords.signal.signal_id,
        "failed to wake managed TUI for active signal delivery"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
fn warn_active_signal_ack_wait_failure(coords: &SignalCoords<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = coords.session_id,
        agent_id = coords.agent_id,
        signal_id = %coords.signal.signal_id,
        "failed while waiting for active signal acknowledgment"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn warn_active_signal_ack_record_failure(coords: &SignalCoords<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = coords.session_id,
        agent_id = coords.agent_id,
        signal_id = %coords.signal.signal_id,
        "failed to record actively delivered signal acknowledgment"
    );
}

fn warn_active_signal_delivery_timeout(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    timeout: Duration,
) {
    let message = format!(
        "session '{session_id}' signal '{signal_id}' to agent '{agent_id}' stayed pending after active TUI wake-up for {} ms",
        timeout.as_millis()
    );
    super::super::state::append_event_best_effort("warn", &message);
    tracing::warn!(
        session_id,
        agent_id,
        signal_id,
        timeout_ms = timeout.as_millis(),
        "active TUI signal delivery timed out"
    );
}

/// Send a signal through the daemon's persistence and wake adapters.
///
/// # Errors
/// Returns an error when the session cannot be resolved or delivery setup fails.
pub fn send_signal(
    session_id: &str,
    request: &SignalSendRequest,
    db: Option<&DaemonDb>,
    manager: Option<&AgentTuiManagerHandle>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::send_signal(
        session_id,
        request,
        db,
        manager.map(|manager| manager as &dyn SignalWake),
    )
}

/// Cancel a pending signal through the daemon persistence adapter.
///
/// # Errors
/// Returns an error when the session or signal cannot be resolved or updated.
pub fn cancel_signal(
    session_id: &str,
    request: &SignalCancelRequest,
    db: Option<&DaemonDb>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::cancel_signal(session_id, request, db)
}

pub(crate) fn record_signal_ack_and_broadcast(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&DaemonDb>,
    sender: Option<&broadcast::Sender<StreamEvent>>,
) -> Result<(), CliError> {
    harness_daemon_session_service::record_signal_ack(
        session_id,
        agent_id,
        signal_id,
        result,
        project_dir,
        db,
    )?;
    if let Some(sender) = sender {
        broadcast_session_snapshot(sender, session_id, db);
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn try_wake_started_workers(
    state: &SessionState,
    effects: &[session_service::TaskDropEffect],
    session_id: &str,
    project_dir: &Path,
    db: Option<&DaemonDb>,
    dispatch: WakeDispatch<'_>,
) {
    for effect in effects {
        let session_service::TaskDropEffect::Started(record) = effect else {
            continue;
        };
        let Some(agent_runtime) = runtime::runtime_for_name(&record.runtime) else {
            tracing::warn!(session_id, agent_id = %record.agent_id, runtime = %record.runtime, signal_id = %record.signal.signal_id, "task wake skipped: unknown runtime");
            continue;
        };
        let registration = state.agents.get(&record.agent_id);
        let route = wake_route_for_registration(registration, dispatch);
        log_wake_attempt(session_id, record.as_ref(), &route);
        match route {
            WakeRoute::Tui { tui_id, manager } => {
                let _ = attempt_active_signal_delivery(
                    session_id,
                    &record.agent_id,
                    &record.signal,
                    agent_runtime,
                    project_dir,
                    &record.signal_session_id,
                    db,
                    Some(tui_id),
                    Some(manager as &dyn SignalWake),
                );
            }
            WakeRoute::Acp { acp_id, manager } => {
                manager.dispatch_wake_prompt(
                    agent_runtime,
                    AcpWakePrompt {
                        acp_id: acp_id.to_string(),
                        orchestration_session_id: session_id.to_string(),
                        signal_session_id: record.signal_session_id.clone(),
                        signal_dir: agent_runtime
                            .signal_dir(project_dir, &record.signal_session_id),
                        project_dir: project_dir.to_path_buf(),
                        prompt: build_active_signal_prompt(&record.signal),
                        signal_id: record.signal.signal_id.clone(),
                        agent_id: record.agent_id.clone(),
                    },
                );
            }
            WakeRoute::Codex { run_id, controller } => {
                let request = CodexSteerRequest {
                    prompt: build_active_signal_prompt(&record.signal),
                };
                if let Err(error) = controller.steer(run_id, &request) {
                    tracing::warn!(session_id, agent_id = %record.agent_id, signal_id = %record.signal.signal_id, %error, "wake skipped: codex steer failed");
                }
            }
            WakeRoute::None { reason } => {
                tracing::warn!(session_id, agent_id = %record.agent_id, signal_id = %record.signal.signal_id, reason = %reason, "wake skipped: signal stays file-only");
            }
        }
    }
}
