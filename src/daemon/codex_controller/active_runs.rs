use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::sync::mpsc;

use crate::daemon::protocol::CodexApprovalDecision;
use crate::errors::{CliError, CliErrorKind};

#[derive(Clone)]
pub(super) struct ActiveRun {
    pub(super) control_tx: mpsc::UnboundedSender<CodexControlMessage>,
}

#[derive(Clone, Default)]
pub(super) struct ActiveRuns {
    entries: Arc<Mutex<HashMap<String, ActiveRun>>>,
}

impl ActiveRuns {
    pub(super) fn insert(
        &self,
        run_id: String,
        control_tx: mpsc::UnboundedSender<CodexControlMessage>,
    ) -> Result<(), CliError> {
        self.lock()?.insert(run_id, ActiveRun { control_tx });
        Ok(())
    }

    pub(super) fn get(&self, run_id: &str) -> Result<ActiveRun, CliError> {
        self.lock()?.get(run_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!("codex run '{run_id}' is not active")).into()
        })
    }

    pub(super) fn remove(&self, run_id: &str) {
        let Ok(mut entries) = self.entries.lock() else {
            return;
        };
        entries.remove(run_id);
    }

    fn lock(&self) -> Result<MutexGuard<'_, HashMap<String, ActiveRun>>, CliError> {
        self.entries.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("codex active run lock poisoned: {error}")).into()
        })
    }
}

#[derive(Debug)]
pub(super) enum CodexControlMessage {
    Approval {
        approval_id: String,
        decision: CodexApprovalDecision,
    },
    Steer {
        prompt: String,
    },
    Interrupt,
}
