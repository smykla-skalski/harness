use std::convert::identity;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::thread;

use serde::Serialize;
use serde_json::json;
use tokio::runtime::{Builder, Handle, RuntimeFlavor};
use tokio::task::block_in_place;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ensure_shared_db};
use crate::daemon::index;
use crate::daemon::protocol::{CodexAgentInspectSnapshot, CodexRunSnapshot, CodexRunStatus};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::events::codex_event;
use super::handle::{
    CodexControllerHandle, lock_db, preferred_codex_project_dir, record_snapshot_event,
};

impl CodexControllerHandle {
    pub(super) fn load_run(&self, run_id: &str) -> Result<CodexRunSnapshot, CliError> {
        let run_id_owned = run_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            async_db.codex_run(&run_id_owned).await?.ok_or_else(|| {
                CliErrorKind::session_not_active(format!("codex run '{run_id_owned}' not found"))
                    .into()
            })
        }) {
            return result;
        }
        let db = self.db()?;
        lock_db(&db)?.codex_run(run_id)?.ok_or_else(|| {
            CliErrorKind::session_not_active(format!("codex run '{run_id}' not found")).into()
        })
    }

    pub(super) fn list_active_runs(&self) -> Result<Vec<CodexRunSnapshot>, CliError> {
        let mut runs = Vec::new();
        for run_id in self.state.active_runs.ids()? {
            if let Ok(run) = self.run(&run_id) {
                runs.push(run);
            }
        }
        runs.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        Ok(runs)
    }

    pub(super) fn inspect_snapshot(&self, run: &CodexRunSnapshot) -> CodexAgentInspectSnapshot {
        let attached = self.state.active_runs.contains(&run.run_id);
        CodexAgentInspectSnapshot {
            run_id: run.run_id.clone(),
            session_id: run.session_id.clone(),
            agent_id: run.session_agent_id.clone(),
            display_name: run
                .display_name
                .clone()
                .unwrap_or_else(|| "Codex".to_string()),
            status: run.status,
            project_dir: run.project_dir.clone(),
            thread_id: run.thread_id.clone(),
            turn_id: run.turn_id.clone(),
            active: run.status.is_active(),
            attached,
            pending_approvals: run.pending_approvals.len(),
            resolved_approvals: run.resolved_approvals.len(),
            event_count: run.events.len(),
            last_update_at: run.updated_at.clone(),
            model: run.model.clone(),
            effort: run.effort.clone(),
            latest_summary: run.latest_summary.clone(),
            error: run.error.clone(),
        }
    }

    pub(super) fn reconcile_stale_runs(
        &self,
        runs: Vec<CodexRunSnapshot>,
    ) -> Result<Vec<CodexRunSnapshot>, CliError> {
        runs.into_iter()
            .map(|run| self.reconcile_run(run))
            .collect()
    }

    pub(super) fn reconcile_run(
        &self,
        mut run: CodexRunSnapshot,
    ) -> Result<CodexRunSnapshot, CliError> {
        if run.status.is_active() && !self.state.active_runs.contains(&run.run_id) {
            run.status = CodexRunStatus::Failed;
            run.latest_summary =
                Some("Codex turn is no longer attached to this daemon".to_string());
            run.error = Some("Codex turn is no longer attached to this daemon".to_string());
            run.pending_approvals.clear();
            run.updated_at = utc_now();
            let payload = json!({
                "runId": run.run_id.clone(),
                "status": "failed",
                "reason": "active turn no longer attached to daemon",
            });
            record_snapshot_event(
                &mut run,
                "agent/reconciled",
                "Codex active turn marked stale".to_string(),
                &payload,
            );
            self.save_and_broadcast(&run)?;
        }
        self.sync_orchestration_status_for_run(&run)?;
        Ok(run)
    }

    pub(super) fn project_dir_for_session(&self, session_id: &str) -> Result<String, CliError> {
        let session_id_owned = session_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            Ok(async_db
                .resolve_session(&session_id_owned)
                .await?
                .map(|resolved| {
                    preferred_codex_project_dir(
                        &resolved.state.worktree_path,
                        resolved.project.project_dir.as_deref(),
                        resolved.project.repository_root.as_deref(),
                        &resolved.project.context_root,
                    )
                }))
        }) && let Some(project_dir) = result?
        {
            return Ok(project_dir);
        }
        let db = self.db()?;
        let guard = lock_db(&db)?;
        if let Some(project_dir) = guard.project_dir_for_session(session_id)? {
            return Ok(project_dir);
        }
        drop(guard);

        let resolved = index::resolve_session(session_id)?;
        Ok(preferred_codex_project_dir(
            &resolved.state.worktree_path,
            resolved.project.project_dir.as_deref(),
            resolved.project.repository_root.as_deref(),
            &resolved.project.context_root,
        ))
    }

    pub(super) fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        ensure_shared_db(&self.state.db)
    }

    pub(super) fn remove_active_run(&self, run_id: &str) {
        self.state.active_runs.remove(run_id);
    }

    #[cfg(test)]
    pub(super) fn poison_active_runs_for_test(&self) {
        self.state.active_runs.poison_for_test();
    }

    pub(super) fn save_and_broadcast(&self, snapshot: &CodexRunSnapshot) -> Result<(), CliError> {
        // The async DB path needs an owned 'static value captured by the async
        // move block.  Clone only inside the FnOnce so the sync fallback path
        // (run_with_async_db returns None) pays no clone cost at all.
        if let Some(result) = self.run_with_async_db(|async_db| {
            let persisted = snapshot.clone();
            async move { async_db.save_codex_run(&persisted).await }
        }) {
            result?;
        } else {
            let db = self.db()?;
            lock_db(&db)?.save_codex_run(snapshot)?;
        }
        self.broadcast("codex_run_updated", snapshot, snapshot);
        Ok(())
    }

    pub(super) fn broadcast<T: Serialize>(
        &self,
        event: &str,
        snapshot: &CodexRunSnapshot,
        payload: &T,
    ) {
        let Some(stream_event) = codex_event(event, snapshot, payload) else {
            return;
        };
        let _ = self.state.sender.send(stream_event);
    }

    pub(super) fn run_with_async_db<T, F, Fut>(&self, task: F) -> Option<Result<T, CliError>>
    where
        F: FnOnce(Arc<AsyncDaemonDb>) -> Fut,
        Fut: Future<Output = Result<T, CliError>> + Send + 'static,
        T: Send + 'static,
    {
        let async_db = self.state.async_db.get()?.clone();
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
                                "build async codex bridge runtime: {error}"
                            )))
                        })?
                        .block_on(future)
                })
                .join()
                .map_err(|_| {
                    CliError::from(CliErrorKind::workflow_io("join async codex bridge thread"))
                })
                .and_then(identity),
                _ => runtime.block_on(future),
            },
            Err(_) => runtime.block_on(future),
        })
    }
}
