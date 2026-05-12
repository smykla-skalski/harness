use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::sync::{mpsc, oneshot};

use crate::daemon::protocol::{CodexApprovalDecision, CodexRunSnapshot};
use crate::errors::{CliError, CliErrorKind};

pub(super) type CodexControlAck = oneshot::Sender<Result<CodexRunSnapshot, CliError>>;

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

    pub(super) fn contains(&self, run_id: &str) -> bool {
        self.entries
            .lock()
            .is_ok_and(|entries| entries.contains_key(run_id))
    }

    pub(super) fn ids(&self) -> Result<Vec<String>, CliError> {
        Ok(self.lock()?.keys().cloned().collect())
    }

    pub(super) fn remove(&self, run_id: &str) {
        let Ok(mut entries) = self.entries.lock() else {
            return;
        };
        entries.remove(run_id);
    }

    #[cfg(test)]
    pub(super) fn poison_for_test(&self) {
        let entries = Arc::clone(&self.entries);
        let _ = std::thread::spawn(move || {
            let _guard = entries.lock().expect("active runs lock");
            panic!("poison active runs for test");
        })
        .join();
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
        ack: CodexControlAck,
    },
    Steer {
        prompt: String,
        ack: CodexControlAck,
    },
    Interrupt {
        ack: CodexControlAck,
    },
    Stop {
        ack: CodexControlAck,
    },
}
