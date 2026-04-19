use std::collections::BTreeMap;
use std::convert::identity;
use std::future::Future;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;

use tokio::runtime::{Builder, Handle, RuntimeFlavor};
use tokio::task::block_in_place;

use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ensure_shared_db};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service::{
    broadcast_session_snapshot, broadcast_session_snapshot_async, disconnect_agent_direct,
    disconnect_agent_direct_async,
};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::LIVE_REFRESH_INTERVAL;
use super::manager::{ActiveAgentTui, AgentTuiManagerHandle};
use super::model::{AgentTuiSnapshot, AgentTuiStatus, session_disconnect_reason};
use super::support::{agent_id_for_tui, lock, lock_db};

impl AgentTuiManagerHandle {
    pub(super) fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        ensure_shared_db(&self.state.db)
    }

    pub(super) fn async_db(&self) -> Option<Arc<AsyncDaemonDb>> {
        self.state.async_db.get().cloned()
    }

    pub(super) fn active(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, ActiveAgentTui>>, CliError> {
        lock(&self.state.active, "terminal agent active process map")
    }

    pub(super) fn run_with_async_db<T, F, Fut>(&self, task: F) -> Option<Result<T, CliError>>
    where
        F: FnOnce(Arc<AsyncDaemonDb>) -> Fut,
        Fut: Future<Output = Result<T, CliError>> + Send + 'static,
        T: Send + 'static,
    {
        let async_db = self.async_db()?;
        let runtime = self.state.runtime.clone()?;
        let future = task(async_db);
        Some(match Handle::try_current() {
            Ok(current) => match current.runtime_flavor() {
                RuntimeFlavor::MultiThread => block_in_place(|| runtime.block_on(future)),
                RuntimeFlavor::CurrentThread => thread::spawn(move || {
                    Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .map_err(|error| {
                            CliError::from(CliErrorKind::workflow_io(format!(
                                "build async terminal agent bridge runtime: {error}"
                            )))
                        })?
                        .block_on(future)
                })
                .join()
                .map_err(|_| {
                    CliError::from(CliErrorKind::workflow_io(
                        "join async terminal agent bridge thread",
                    ))
                })
                .and_then(identity),
                _ => runtime.block_on(future),
            },
            Err(_) => runtime.block_on(future),
        })
    }

    pub(crate) fn active_process(
        &self,
        tui_id: &str,
    ) -> Result<Arc<super::AgentTuiProcess>, CliError> {
        self.active()?
            .get(tui_id)
            .and_then(|active| active.process.clone())
            .ok_or_else(|| {
                CliErrorKind::session_not_active(format!("terminal agent '{tui_id}' is not active"))
                    .into()
            })
    }

    pub(crate) fn remove_active(
        &self,
        tui_id: &str,
    ) -> Result<Option<Arc<super::AgentTuiProcess>>, CliError> {
        let removed = self.active()?.remove(tui_id);
        if let Some(active) = &removed {
            active.stop();
        }
        Ok(removed.and_then(|active| active.process))
    }

    pub(super) fn load_snapshot(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let tui_id_owned = tui_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            async_db.agent_tui(&tui_id_owned).await?.ok_or_else(|| {
                CliErrorKind::session_not_active(format!(
                    "terminal agent '{tui_id_owned}' not found"
                ))
                .into()
            })
        }) {
            return result;
        }
        let db = self.db()?;
        lock_db(&db)?.agent_tui(tui_id)?.ok_or_else(|| {
            CliErrorKind::session_not_active(format!("terminal agent '{tui_id}' not found")).into()
        })
    }

    pub(crate) fn is_tui_active(&self, tui_id: &str) -> Result<bool, CliError> {
        let active = self.active()?;
        if self.state.sandboxed {
            return Ok(active.contains_key(tui_id));
        }
        Ok(active
            .get(tui_id)
            .and_then(|entry| entry.process.as_ref())
            .is_some())
    }

    pub(crate) fn refresh_live_snapshot(
        &self,
        snapshot: AgentTuiSnapshot,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed && snapshot.status == AgentTuiStatus::Running {
            let snapshot = BridgeClient::for_capability(BridgeCapability::AgentTui)?
                .agent_tui_get(&snapshot.tui_id)?;
            return Ok(self.normalize_snapshot(snapshot));
        }
        self.refresh_local_snapshot(snapshot)
    }

    pub(super) fn refresh_local_snapshot(
        &self,
        mut snapshot: AgentTuiSnapshot,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let Some(process) = self
            .active()?
            .get(&snapshot.tui_id)
            .and_then(|active| active.process.clone())
        else {
            return Ok(snapshot);
        };

        if let Some(status) = process.try_wait()? {
            snapshot.status = AgentTuiStatus::Exited;
            snapshot.exit_code = Some(status.exit_code());
            snapshot.signal = status.signal().map(ToString::to_string);
            let _ = self.remove_active(&snapshot.tui_id)?;
        }

        snapshot.screen = process.screen()?;
        snapshot.size = snapshot.screen.size();
        snapshot.updated_at = utc_now();
        process.persist_transcript(Path::new(&snapshot.transcript_path))?;

        if snapshot.agent_id.is_empty() {
            self.try_resolve_agent_id(&mut snapshot);
        }

        Ok(snapshot)
    }

    fn try_resolve_agent_id(&self, snapshot: &mut AgentTuiSnapshot) {
        let marker = format!("agent-tui:{}", snapshot.tui_id);
        let session_id = snapshot.session_id.clone();
        let async_marker = marker.clone();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            Ok(async_db
                .resolve_session(&session_id)
                .await?
                .and_then(|resolved| agent_id_for_tui(&resolved.state, &async_marker).ok()))
        }) {
            if let Ok(Some(agent_id)) = result {
                snapshot.agent_id = agent_id;
            }
            return;
        }
        let Ok(db) = self.db() else {
            return;
        };
        let Ok(db_guard) = lock_db(&db) else {
            return;
        };
        let Ok(Some(state)) = db_guard.load_session_state(&snapshot.session_id) else {
            return;
        };
        if let Ok(agent_id) = agent_id_for_tui(&state, &marker) {
            snapshot.agent_id = agent_id;
        }
    }

    pub(crate) fn normalize_snapshot(&self, mut snapshot: AgentTuiSnapshot) -> AgentTuiSnapshot {
        if snapshot.agent_id.is_empty() {
            self.try_resolve_agent_id(&mut snapshot);
        }
        snapshot
    }

    pub(super) fn persist_refreshed_snapshot(
        &self,
        previous: &AgentTuiSnapshot,
        refreshed: &AgentTuiSnapshot,
    ) -> Result<(), CliError> {
        if !Self::snapshot_changed(previous, refreshed) {
            return Ok(());
        }
        self.save_and_broadcast("agent_tui_updated", refreshed)
    }

    fn snapshot_changed(previous: &AgentTuiSnapshot, refreshed: &AgentTuiSnapshot) -> bool {
        previous.status != refreshed.status
            || previous.size != refreshed.size
            || previous.screen != refreshed.screen
            || previous.exit_code != refreshed.exit_code
            || previous.signal != refreshed.signal
            || previous.error != refreshed.error
            || previous.agent_id != refreshed.agent_id
    }

    pub(crate) fn spawn_live_refresh(&self, tui_id: String, stop_flag: Arc<AtomicBool>) {
        let manager = self.clone();
        let _ = thread::spawn(move || {
            manager.run_live_refresh_loop(&tui_id, &stop_flag);
        });
    }

    fn run_live_refresh_loop(&self, tui_id: &str, stop_flag: &AtomicBool) {
        while Self::wait_for_live_refresh_tick(stop_flag) && self.handle_live_refresh_step(tui_id) {
        }

        let _ = self.remove_active(tui_id);
    }

    fn wait_for_live_refresh_tick(stop_flag: &AtomicBool) -> bool {
        if stop_flag.load(Ordering::Relaxed) {
            return false;
        }
        thread::sleep(LIVE_REFRESH_INTERVAL);
        !stop_flag.load(Ordering::Relaxed)
    }

    fn handle_live_refresh_step(&self, tui_id: &str) -> bool {
        self.live_refresh_step(tui_id).unwrap_or_else(|error| {
            Self::warn_live_refresh_failure(tui_id, &error);
            false
        })
    }

    fn live_refresh_step(&self, tui_id: &str) -> Result<bool, CliError> {
        let previous = self.load_snapshot(tui_id)?;
        if previous.status != AgentTuiStatus::Running {
            return Ok(false);
        }

        let refreshed = self.refresh_live_snapshot(previous.clone())?;
        if let Some(status) = self.live_refresh_skip_status(tui_id, &previous.updated_at)? {
            return Ok(status == AgentTuiStatus::Running);
        }
        self.persist_refreshed_snapshot(&previous, &refreshed)?;
        Ok(refreshed.status == AgentTuiStatus::Running)
    }

    pub(super) fn live_refresh_skip_status(
        &self,
        tui_id: &str,
        previous_updated_at: &str,
    ) -> Result<Option<AgentTuiStatus>, CliError> {
        let tui_id_owned = tui_id.to_string();
        let previous_updated_at = previous_updated_at.to_string();
        let previous_updated_at_sync = previous_updated_at.clone();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            Ok(async_db
                .agent_tui_live_refresh_state(&tui_id_owned)
                .await?
                .filter(|state| state.updated_at.as_str() > previous_updated_at.as_str())
                .map(|state| state.status))
        }) {
            return result;
        }
        let db = self.db()?;
        let current = lock_db(&db)?.agent_tui_live_refresh_state(tui_id)?;
        Ok(current
            .filter(|state| state.updated_at.as_str() > previous_updated_at_sync.as_str())
            .map(|state| state.status))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion in a leaf logging helper"
    )]
    fn warn_live_refresh_failure(tui_id: &str, error: &CliError) {
        tracing::warn!(tui_id = %tui_id, %error, "terminal agent live refresh failed");
    }

    pub(super) fn save_and_broadcast(
        &self,
        event_name: &str,
        snapshot: &AgentTuiSnapshot,
    ) -> Result<(), CliError> {
        let snapshot = self.normalize_snapshot(snapshot.clone());
        let persisted = snapshot.clone();
        if let Some(result) = self
            .run_with_async_db(|async_db| async move { async_db.save_agent_tui(&persisted).await })
        {
            result?;
        } else {
            let db = self.db()?;
            lock_db(&db)?.save_agent_tui(&snapshot)?;
        }
        let session_id = snapshot.session_id.clone();
        let payload = serde_json::to_value(&snapshot).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("serialize terminal agent event: {error}"))
        })?;
        let event = StreamEvent {
            event: event_name.to_string(),
            recorded_at: utc_now(),
            session_id: Some(session_id),
            payload,
        };
        let _ = self.state.sender.send(event);
        self.reconcile_terminal_agent_state(&snapshot)?;
        Ok(())
    }

    fn reconcile_terminal_agent_state(&self, snapshot: &AgentTuiSnapshot) -> Result<(), CliError> {
        let Some(reason) = session_disconnect_reason(snapshot.status) else {
            return Ok(());
        };
        if snapshot.agent_id.is_empty() {
            return Ok(());
        }

        let session_id = snapshot.session_id.clone();
        let agent_id = snapshot.agent_id.clone();
        let sender = self.state.sender.clone();
        let reason_owned = reason.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            let disconnected =
                disconnect_agent_direct_async(&session_id, &agent_id, &reason_owned, &async_db)
                    .await?;
            if disconnected {
                broadcast_session_snapshot_async(&sender, &session_id, Some(&async_db)).await;
            }
            Ok(())
        }) {
            return result;
        }

        let db = self.db()?;
        let db_guard = lock_db(&db)?;
        if disconnect_agent_direct(
            &snapshot.session_id,
            &snapshot.agent_id,
            reason,
            Some(&db_guard),
        )? {
            broadcast_session_snapshot(&self.state.sender, &snapshot.session_id, Some(&db_guard));
        }
        Ok(())
    }
}
