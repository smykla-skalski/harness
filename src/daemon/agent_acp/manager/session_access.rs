use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;

use super::service;
use super::{
    AcpAgentManagerHandle, AcpAgentSnapshot, AcpPermissionBatch, AcpPermissionDecision,
    ActiveAcpSession,
};
use crate::agents::runtime::AgentRuntime;
use crate::agents::runtime::signal::{AckResult, SignalAck, acknowledge_signal};
use crate::daemon::service::{WakeEventLevel, record_wake_event};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

/// Wake-prompt invocation context. Bundles the protocol coordinates and the
/// signal-side identity needed to synthesise an `Accept` ack on success.
#[derive(Debug)]
pub struct AcpWakePrompt {
    pub acp_id: String,
    pub orchestration_session_id: String,
    pub protocol_session_id: String,
    pub project_dir: PathBuf,
    pub prompt: String,
    pub signal_id: String,
    pub agent_id: String,
}

impl AcpAgentManagerHandle {
    /// Best-effort wake an ACP-managed agent by issuing an active
    /// `session/prompt` over the protocol channel.
    ///
    /// The prompt call is potentially long-running (the agent may stream tool
    /// calls before the response settles) so it is dispatched on a dedicated
    /// OS thread rather than blocking the caller. On success the runtime ack
    /// file is written so the file-poll fallback consumer (and the daemon
    /// reconciler) sees the signal as `Accept`-ed; this closes the wake loop
    /// the file-only path used to leave open. Failures are logged at `warn!`;
    /// the pending signal record stays on disk so the agent still picks the
    /// task up on its next file scan.
    ///
    /// Back-pressure: an in-flight guard keyed by `(acp_id, signal_id)` keeps
    /// a single live wake per signal even under a storm of `task.drop` calls.
    /// Coalesced wakes return immediately at `info!`. The agent will still
    /// see the file signal on its next poll.
    pub fn dispatch_wake_prompt(&self, runtime: &'static dyn AgentRuntime, prompt: AcpWakePrompt) {
        let session = match self.session(&prompt.acp_id) {
            Ok(session) => session,
            Err(error) => {
                record_wake_event(
                    WakeEventLevel::Warn,
                    "skipped",
                    &[
                        ("acp_id", &prompt.acp_id),
                        ("signal_id", &prompt.signal_id),
                        ("reason", &"session_not_active"),
                        ("error", &error),
                    ],
                );
                return;
            }
        };
        if !self.try_reserve_wake(&prompt.acp_id, &prompt.signal_id) {
            record_wake_event(
                WakeEventLevel::Info,
                "coalesced",
                &[("acp_id", &prompt.acp_id), ("signal_id", &prompt.signal_id)],
            );
            return;
        }
        let manager = self.clone();
        let acp_id_for_diag = prompt.acp_id.clone();
        let thread_name = format!("acp-wake-{}", prompt.acp_id);
        if let Err(error) = thread::Builder::new()
            .name(thread_name)
            .spawn(move || run_wake_prompt(&manager, runtime, &session, prompt))
        {
            record_wake_event(
                WakeEventLevel::Error,
                "thread_spawn_failed",
                &[("acp_id", &acp_id_for_diag), ("error", &error)],
            );
        }
    }

    fn try_reserve_wake(&self, acp_id: &str, signal_id: &str) -> bool {
        let mut guard = match self.state.wake_in_flight.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        guard.insert((acp_id.to_string(), signal_id.to_string()))
    }

    fn release_wake(&self, acp_id: &str, signal_id: &str) {
        let mut guard = match self.state.wake_in_flight.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        guard.remove(&(acp_id.to_string(), signal_id.to_string()));
    }

    /// Resolve a pending ACP permission batch and return the updated snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] when the ACP session or permission batch is unknown.
    pub fn resolve_permission_batch(
        &self,
        acp_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<AcpAgentSnapshot, CliError> {
        if service::sandboxed_from_env() {
            return self.resolve_permission_batch_via_bridge(acp_id, batch_id, decision);
        }
        let session = self.session(acp_id)?;
        if !session.resolve_permission_batch(batch_id, decision) {
            return Err(CliErrorKind::session_not_active(format!(
                "permission_batch_stale: ACP permission batch '{batch_id}' is not pending for session '{acp_id}'"
            ))
            .into());
        }
        let snapshot = session.snapshot_with_live_counts();
        self.broadcast("acp_permission_batch_resolved", &snapshot);
        Ok(snapshot)
    }

    #[must_use]
    /// Return the number of pending ACP permission prompts for one ACP session.
    pub fn pending_permission_count(&self, acp_id: &str) -> Option<usize> {
        if service::sandboxed_from_env() {
            return self.pending_permission_count_via_bridge(acp_id);
        }
        let sessions = self.sessions_guard().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_count())
    }

    #[must_use]
    /// Return the queued ACP permission batches for one ACP session.
    pub fn pending_permission_batches(&self, acp_id: &str) -> Option<Vec<AcpPermissionBatch>> {
        if service::sandboxed_from_env() {
            return self.pending_permission_batches_via_bridge(acp_id);
        }
        let sessions = self.sessions_guard().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_batches())
    }

    pub(super) fn session(&self, acp_id: &str) -> Result<Arc<ActiveAcpSession>, CliError> {
        self.sessions_guard()?.get(acp_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!("ACP session '{acp_id}' not found")).into()
        })
    }

    pub(super) fn sessions_for(
        &self,
        session_id: &str,
    ) -> Result<Vec<Arc<ActiveAcpSession>>, CliError> {
        Ok(self
            .sessions_guard()?
            .values()
            .filter(|session| session.session_id() == session_id)
            .cloned()
            .collect())
    }
}

fn run_wake_prompt(
    manager: &AcpAgentManagerHandle,
    runtime: &'static dyn AgentRuntime,
    session: &Arc<ActiveAcpSession>,
    prompt: AcpWakePrompt,
) {
    let AcpWakePrompt {
        acp_id,
        orchestration_session_id,
        protocol_session_id,
        project_dir,
        prompt: prompt_text,
        signal_id,
        agent_id,
    } = prompt;
    let result = session.prompt_protocol_session(
        &acp_id,
        &protocol_session_id,
        project_dir.clone(),
        prompt_text,
    );
    match result {
        Ok(returned_session_id) => {
            record_wake_event(
                WakeEventLevel::Info,
                "dispatched",
                &[
                    ("acp_id", &acp_id),
                    ("protocol_session_id", &returned_session_id),
                    ("signal_id", &signal_id),
                    ("agent_id", &agent_id),
                ],
            );
            if record_wake_accept(
                runtime,
                &project_dir,
                &returned_session_id,
                &signal_id,
                &agent_id,
                &acp_id,
            ) {
                if let Some(emitter) = session.event_emitter() {
                    emitter.emit_context_injected(
                        "acp".to_string(),
                        Some(format!(
                            "wake prompt accepted (signal {signal_id})"
                        )),
                    );
                }
                sync_wake_accept_to_daemon(
                    manager,
                    &orchestration_session_id,
                    &agent_id,
                    &signal_id,
                    &project_dir,
                    &acp_id,
                );
            }
        }
        Err(error) => {
            record_wake_event(
                WakeEventLevel::Warn,
                "failed",
                &[
                    ("acp_id", &acp_id),
                    ("protocol_session_id", &protocol_session_id),
                    ("signal_id", &signal_id),
                    ("error", &error),
                ],
            );
        }
    }
    manager.release_wake(&acp_id, &signal_id);
}

fn record_wake_accept(
    runtime: &'static dyn AgentRuntime,
    project_dir: &Path,
    protocol_session_id: &str,
    signal_id: &str,
    agent_id: &str,
    acp_id: &str,
) -> bool {
    let signal_dir = runtime.signal_dir(project_dir, protocol_session_id);
    let ack = SignalAck {
        signal_id: signal_id.to_string(),
        acknowledged_at: utc_now(),
        result: AckResult::Accepted,
        agent: agent_id.to_string(),
        session_id: protocol_session_id.to_string(),
        details: Some("acp wake prompt acknowledged via session/prompt".into()),
    };
    match acknowledge_signal(&signal_dir, &ack) {
        Ok(()) => {
            record_wake_event(
                WakeEventLevel::Info,
                "accepted",
                &[
                    ("acp_id", &acp_id),
                    ("protocol_session_id", &protocol_session_id),
                    ("signal_id", &signal_id),
                    ("agent_id", &agent_id),
                ],
            );
            true
        }
        Err(error) => {
            record_wake_event(
                WakeEventLevel::Warn,
                "ack_write_failed",
                &[
                    ("acp_id", &acp_id),
                    ("protocol_session_id", &protocol_session_id),
                    ("signal_id", &signal_id),
                    ("error", &error),
                ],
            );
            false
        }
    }
}

fn sync_wake_accept_to_daemon(
    manager: &AcpAgentManagerHandle,
    orchestration_session_id: &str,
    agent_id: &str,
    signal_id: &str,
    project_dir: &Path,
    acp_id: &str,
) {
    let db = match manager.db() {
        Ok(db) => db,
        Err(error) => {
            record_wake_event(
                WakeEventLevel::Warn,
                "ack_sync_skipped",
                &[
                    ("acp_id", &acp_id),
                    ("signal_id", &signal_id),
                    ("error", &error),
                ],
            );
            return;
        }
    };
    let db = match db.lock() {
        Ok(guard) => guard,
        Err(error) => {
            record_wake_event(
                WakeEventLevel::Warn,
                "ack_sync_lock_poisoned",
                &[
                    ("acp_id", &acp_id),
                    ("signal_id", &signal_id),
                    ("error", &error),
                ],
            );
            error.into_inner()
        }
    };
    if let Err(error) = service::record_signal_ack_and_broadcast(
        orchestration_session_id,
        agent_id,
        signal_id,
        AckResult::Accepted,
        project_dir,
        Some(&db),
        Some(&manager.state.sender),
    ) {
        record_wake_event(
            WakeEventLevel::Warn,
            "ack_sync_failed",
            &[
                ("acp_id", &acp_id),
                ("signal_id", &signal_id),
                ("error", &error),
            ],
        );
    }
}
