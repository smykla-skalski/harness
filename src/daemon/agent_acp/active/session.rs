use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::task::JoinHandle;

use crate::agents::kind::DisconnectReason;
use crate::daemon::agent_acp::manager::{AcpAgentInspectSnapshot, AcpAgentSnapshot};
use crate::daemon::agent_acp::permission_bridge::{
    AcpPermissionBatch, AcpPermissionDecision, PermissionBridgeHandle,
};
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::{ActiveAcpProcess, recover_lock};

pub(in crate::daemon::agent_acp) struct ActiveAcpSession {
    acp_id: String,
    snapshot: Mutex<AcpAgentSnapshot>,
    permissions: PermissionBridgeHandle,
    process: Arc<ActiveAcpProcess>,
}

impl ActiveAcpSession {
    #[must_use]
    pub(in crate::daemon::agent_acp) fn new(
        snapshot: AcpAgentSnapshot,
        permissions: PermissionBridgeHandle,
        process: Arc<ActiveAcpProcess>,
    ) -> Self {
        process.add_logical_session(&snapshot.acp_id);
        Self {
            acp_id: snapshot.acp_id.clone(),
            snapshot: Mutex::new(snapshot),
            permissions,
            process,
        }
    }

    pub(in crate::daemon::agent_acp) fn process_key(&self) -> String {
        self.snapshot_guard().process_key.clone()
    }

    pub(in crate::daemon::agent_acp) fn process(&self) -> Arc<ActiveAcpProcess> {
        Arc::clone(&self.process)
    }

    pub(in crate::daemon::agent_acp) fn attach_protocol_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
    ) -> Result<String, String> {
        self.process
            .attach_protocol_session(acp_id, session_id, project_dir)
    }

    pub(in crate::daemon::agent_acp) fn prompt_protocol_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
        prompt: String,
    ) -> Result<String, String> {
        self.process
            .prompt_protocol_session(acp_id, session_id, project_dir, prompt)
    }

    pub(in crate::daemon::agent_acp) fn detach_protocol_session(
        &self,
        acp_id: &str,
        session_id: &str,
    ) -> Result<(), String> {
        self.process.detach_protocol_session(acp_id, session_id)
    }

    pub(in crate::daemon::agent_acp) fn set_protocol_disconnect_task(&self, task: JoinHandle<()>) {
        self.process.set_protocol_disconnect_task(task);
    }

    pub(in crate::daemon::agent_acp) fn set_watchdog_task(&self, task: JoinHandle<()>) {
        self.process.set_watchdog_task(task);
    }

    pub(in crate::daemon::agent_acp) fn session_id(&self) -> String {
        self.snapshot_guard().session_id.clone()
    }

    pub(in crate::daemon::agent_acp) fn pending_permission_count(&self) -> usize {
        self.permissions.pending_permission_count()
    }

    pub(in crate::daemon::agent_acp) fn pending_permission_batches(
        &self,
    ) -> Vec<AcpPermissionBatch> {
        self.permissions.pending_batches()
    }

    pub(in crate::daemon::agent_acp) fn resolve_permission_batch(
        &self,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> bool {
        self.permissions.resolve_batch(batch_id, decision).is_some()
    }

    pub(in crate::daemon::agent_acp) fn snapshot_with_live_counts(&self) -> AcpAgentSnapshot {
        let mut snapshot = self.snapshot_guard().clone();
        snapshot.pending_permissions = self.permissions.pending_permission_count();
        snapshot.permission_queue_depth = self.permissions.queue_depth();
        snapshot.pending_permission_batches = self.permissions.pending_batches();
        snapshot
    }

    pub(in crate::daemon::agent_acp) fn inspect_snapshot(&self) -> AcpAgentInspectSnapshot {
        let snapshot = self.snapshot_with_live_counts();
        let prompt_timeout = self.process.supervisor.config().prompt_timeout;
        let elapsed_since_last_event = self.process.supervisor.elapsed_since_last_event();
        let remaining = prompt_timeout
            .checked_sub(elapsed_since_last_event)
            .unwrap_or_default();
        AcpAgentInspectSnapshot {
            acp_id: snapshot.acp_id,
            session_id: snapshot.session_id,
            agent_id: snapshot.agent_id,
            display_name: snapshot.display_name,
            pid: snapshot.pid,
            pgid: snapshot.pgid,
            process_key: snapshot.process_key,
            uptime_ms: u64::try_from(self.process.started_at.elapsed().as_millis())
                .unwrap_or(u64::MAX),
            last_update_at: snapshot.updated_at,
            last_client_call_at: self.process.supervisor.last_client_call_at(),
            watchdog_state: self
                .process
                .supervisor
                .watchdog_state()
                .as_str()
                .to_string(),
            permission_mode: snapshot.permission_mode,
            permission_log_path: snapshot.permission_log_path,
            pending_permissions: snapshot.pending_permissions,
            permission_queue_depth: snapshot.permission_queue_depth,
            terminal_count: snapshot.terminal_count,
            prompt_deadline_remaining_ms: u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
        }
    }

    pub(in crate::daemon::agent_acp) fn refresh(&self) {
        if self.snapshot_guard().status.is_disconnected() {
            return;
        }
        if let Some(reason) = self.process.refresh_disconnect_reason() {
            self.disconnect(reason, false);
        }
    }

    pub(in crate::daemon::agent_acp) fn disconnect_for_stop(&self) -> Result<usize, String> {
        self.disconnect_inner(DisconnectReason::SessionStopped, false, true)
    }

    pub(in crate::daemon::agent_acp) fn disconnect(
        &self,
        reason: DisconnectReason,
        terminate_process: bool,
    ) -> usize {
        self.disconnect_inner(reason, terminate_process, false)
            .unwrap_or_else(|error| self.continue_after_detach_failure(&error))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn continue_after_detach_failure(&self, error: &str) -> usize {
        tracing::warn!(%error, "continuing ACP disconnect after detach failure");
        self.permissions.shutdown_pending()
    }

    fn disconnect_inner(
        &self,
        reason: DisconnectReason,
        terminate_process: bool,
        fail_on_detach: bool,
    ) -> Result<usize, String> {
        let (acp_id, mut snapshot) =
            self.detach_protocol_route_if_needed(&reason, terminate_process, fail_on_detach)?;
        if terminate_process {
            self.process.request_cancel();
            self.process.abort_non_protocol_tasks();
            self.process.supervisor.mark_done();
        }
        let pending_permissions = self.permissions.shutdown_pending();
        if snapshot.status.is_disconnected() {
            return Ok(pending_permissions);
        }
        snapshot.status = AgentStatus::Disconnected {
            reason,
            stderr_tail: self.process.stderr_tail.as_string(),
        };
        snapshot.updated_at = utc_now();
        drop(snapshot);
        self.process.remove_logical_session(&acp_id);
        Ok(pending_permissions)
    }

    fn detach_protocol_route_if_needed(
        &self,
        reason: &DisconnectReason,
        terminate_process: bool,
        fail_on_detach: bool,
    ) -> Result<(String, MutexGuard<'_, AcpAgentSnapshot>), String> {
        let mut snapshot = self.snapshot_guard();
        let (acp_id, session_id) = snapshot_route(&snapshot);
        if should_detach_protocol_route(&snapshot, reason, terminate_process) {
            drop(snapshot);
            self.detach_protocol_route(&acp_id, &session_id, fail_on_detach)?;
            snapshot = self.snapshot_guard();
        }
        Ok((acp_id, snapshot))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn detach_protocol_route(
        &self,
        acp_id: &str,
        session_id: &str,
        fail_on_detach: bool,
    ) -> Result<(), String> {
        if let Err(error) = self.process.detach_protocol_session(acp_id, session_id) {
            if fail_on_detach {
                return Err(error);
            }
            tracing::warn!(%error, acp_id, session_id, "failed to detach ACP protocol session");
        }
        Ok(())
    }

    pub(in crate::daemon::agent_acp) fn terminate_process(&self, pending_permissions: usize) {
        self.process.supervisor.mark_done();
        self.process.shutdown(pending_permissions);
    }

    #[cfg(test)]
    pub(in crate::daemon::agent_acp) fn poison_permission_bridge_pending_lock_for_test(&self) {
        self.permissions.poison_pending_lock_for_test();
    }

    fn snapshot_guard(&self) -> MutexGuard<'_, AcpAgentSnapshot> {
        recover_lock(&self.snapshot, "ACP snapshot lock")
    }
}

fn snapshot_route(snapshot: &AcpAgentSnapshot) -> (String, String) {
    (snapshot.acp_id.clone(), snapshot.session_id.clone())
}

fn should_detach_protocol_route(
    snapshot: &AcpAgentSnapshot,
    reason: &DisconnectReason,
    terminate_process: bool,
) -> bool {
    matches!(reason, DisconnectReason::SessionStopped)
        && !terminate_process
        && !snapshot.status.is_disconnected()
}

impl Drop for ActiveAcpSession {
    fn drop(&mut self) {
        let should_terminate = !self.snapshot_guard().status.is_disconnected();
        let _ = self.permissions.shutdown_pending();
        self.process.remove_logical_session(&self.acp_id);
        if should_shutdown_process(should_terminate, &self.process) {
            self.process.shutdown_immediate();
        }
    }
}

fn should_shutdown_process(should_terminate: bool, process: &ActiveAcpProcess) -> bool {
    should_terminate && process.logical_session_count() == 0
}
