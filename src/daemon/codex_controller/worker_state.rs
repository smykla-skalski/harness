use std::time::Duration;
use std::time::Instant;

use serde_json::Value;

use crate::daemon::protocol::CodexRunStatus;
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::handle::record_snapshot_event;
use super::worker::CodexRunWorker;

const DELTA_PERSIST_INTERVAL: Duration = Duration::from_millis(750);

impl CodexRunWorker {
    pub(super) fn thread_id(&self) -> Result<String, CliError> {
        self.snapshot
            .thread_id
            .clone()
            .ok_or_else(|| CliErrorKind::workflow_io("codex thread id is not ready").into())
    }

    pub(super) fn turn_id(&self) -> Result<String, CliError> {
        self.snapshot
            .turn_id
            .clone()
            .ok_or_else(|| CliErrorKind::workflow_io("codex turn id is not ready").into())
    }

    pub(super) fn transition(
        &mut self,
        status: CodexRunStatus,
        latest_summary: Option<&str>,
        error: Option<String>,
    ) -> Result<(), CliError> {
        self.snapshot.status = status;
        if let Some(summary) = latest_summary {
            self.snapshot.latest_summary = Some(summary.to_string());
        }
        self.snapshot.error = error;
        self.touch_and_save()?;
        self.controller
            .sync_orchestration_status_for_run(&self.snapshot)
    }

    pub(super) fn fail(&mut self, message: &str) {
        self.mark_failed(message);
        self.persist_failure(message);
    }

    fn mark_failed(&mut self, message: &str) {
        let message = message.to_string();
        self.snapshot.status = CodexRunStatus::Failed;
        self.snapshot.latest_summary = Some(message.clone());
        self.snapshot.error = Some(message);
        self.snapshot.updated_at = utc_now();
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion; tokio-rs/tracing#553"
    )]
    fn persist_failure(&self, message: &str) {
        if let Err(error) = self.controller.save_and_broadcast(&self.snapshot) {
            tracing::warn!(%error, "failed to persist codex failure");
        }
        if let Err(error) = self
            .controller
            .sync_orchestration_status_for_run(&self.snapshot)
        {
            tracing::warn!(%error, "failed to sync codex failure status to session agent");
        }
        tracing::error!(
            session_id = %self.snapshot.session_id,
            run_id = %self.snapshot.run_id,
            error_message = message,
            "codex run failed"
        );
        state::append_event_best_effort(
            "warn",
            &format!(
                "codex run failed for session {} run {}: {message}",
                self.snapshot.session_id, self.snapshot.run_id
            ),
        );
    }

    pub(super) fn touch_and_save(&mut self) -> Result<(), CliError> {
        self.snapshot.updated_at = utc_now();
        self.controller.save_and_broadcast(&self.snapshot)
    }

    pub(super) fn touch_save_and_sync_orchestration(&mut self) -> Result<(), CliError> {
        self.touch_and_save()?;
        self.controller
            .sync_orchestration_status_for_run(&self.snapshot)
    }

    pub(super) fn record_event(&mut self, kind: &str, summary: String, payload: &Value) {
        record_snapshot_event(&mut self.snapshot, kind, summary, payload);
    }

    pub(super) fn should_persist_delta_update(&mut self) -> bool {
        let now = Instant::now();
        if self
            .last_delta_persist_at
            .is_some_and(|last| now.duration_since(last) < DELTA_PERSIST_INTERVAL)
        {
            return false;
        }
        self.last_delta_persist_at = Some(now);
        true
    }
}
