use std::collections::{HashMap, hash_map::Entry};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};

use crate::daemon::protocol::{CodexApprovalDecision, CodexRunSnapshot};
use crate::errors::{CliError, CliErrorKind};

const STARTUP_WAIT_TIMEOUT: Duration = Duration::from_secs(30);

pub(super) type CodexControlAck = oneshot::Sender<Result<CodexRunSnapshot, CliError>>;

#[derive(Clone)]
pub(super) struct ActiveRun {
    pub(super) control_tx: mpsc::UnboundedSender<CodexControlMessage>,
}

enum ActiveRunEntry {
    Starting(Arc<StartupSignal>),
    Active(ActiveRun),
}

pub(super) enum ActiveRunRegistration {
    Acquired(ActiveRunReservation),
    Waiting(ActiveRunWaiter),
    Active,
}

pub(super) struct ActiveRunReservation {
    entries: Arc<Mutex<HashMap<String, ActiveRunEntry>>>,
    run_id: String,
    startup: Arc<StartupSignal>,
    finished: bool,
}

impl ActiveRunReservation {
    pub(super) fn commit(
        mut self,
        control_tx: mpsc::UnboundedSender<CodexControlMessage>,
        snapshot: CodexRunSnapshot,
    ) -> Result<(), CliError> {
        let mut entries = lock_entries(&self.entries)?;
        let owns_registration = matches!(
            entries.get(&self.run_id),
            Some(ActiveRunEntry::Starting(startup))
                if Arc::ptr_eq(startup, &self.startup)
        );
        if !owns_registration {
            return Err(lost_reservation_error(&self.run_id));
        }
        self.startup.mark_ready(snapshot)?;
        entries.insert(
            self.run_id.clone(),
            ActiveRunEntry::Active(ActiveRun { control_tx }),
        );
        self.finished = true;
        Ok(())
    }

    pub(super) fn abort(mut self, error: &CliError) {
        self.abort_inner(&error.to_string());
    }

    fn abort_inner(&mut self, error: &str) {
        if self.finished {
            return;
        }
        let removed = if let Ok(mut entries) = self.entries.lock() {
            let owns_registration = matches!(
                entries.get(&self.run_id),
                Some(ActiveRunEntry::Starting(startup))
                    if Arc::ptr_eq(startup, &self.startup)
            );
            if owns_registration {
                entries.remove(&self.run_id);
            }
            owns_registration
        } else {
            self.startup.mark_failed(error);
            self.finished = true;
            return;
        };
        if removed {
            self.startup.mark_failed(error);
        }
        self.finished = true;
    }
}

impl Drop for ActiveRunReservation {
    fn drop(&mut self) {
        let error = format!(
            "codex run '{}' startup reservation was abandoned",
            self.run_id
        );
        self.abort_inner(&error);
    }
}

pub(super) struct ActiveRunWaiter {
    run_id: String,
    startup: Arc<StartupSignal>,
}

impl ActiveRunWaiter {
    pub(super) fn wait(&self) -> Result<CodexRunSnapshot, CliError> {
        self.wait_with_timeout(STARTUP_WAIT_TIMEOUT)
    }

    fn wait_with_timeout(&self, timeout: Duration) -> Result<CodexRunSnapshot, CliError> {
        self.startup.wait_until_ready(&self.run_id, timeout)
    }
}

struct StartupSignal {
    state: Mutex<StartupState>,
    changed: Condvar,
}

enum StartupState {
    Starting,
    Ready(Box<CodexRunSnapshot>),
    Failed(String),
}

impl StartupSignal {
    fn new() -> Self {
        Self {
            state: Mutex::new(StartupState::Starting),
            changed: Condvar::new(),
        }
    }

    fn wait_until_ready(
        &self,
        run_id: &str,
        timeout: Duration,
    ) -> Result<CodexRunSnapshot, CliError> {
        let state = self.lock()?;
        let (state, wait_result) = self
            .changed
            .wait_timeout_while(state, timeout, |state| {
                matches!(state, StartupState::Starting)
            })
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "codex run startup lock poisoned: {error}"
                )))
            })?;
        match &*state {
            StartupState::Ready(snapshot) => Ok(snapshot.as_ref().clone()),
            StartupState::Failed(error) => Err(CliErrorKind::workflow_io(error.clone()).into()),
            StartupState::Starting if wait_result.timed_out() => Err(CliErrorKind::workflow_io(
                format!("codex run '{run_id}' startup did not complete within 30s"),
            )
            .into()),
            StartupState::Starting => Err(CliErrorKind::workflow_io(format!(
                "codex run '{run_id}' startup wait ended unexpectedly"
            ))
            .into()),
        }
    }

    fn mark_ready(&self, snapshot: CodexRunSnapshot) -> Result<(), CliError> {
        let mut state = self.lock()?;
        if !matches!(*state, StartupState::Starting) {
            return Err(CliErrorKind::session_agent_conflict(
                "codex run startup reservation is no longer pending",
            )
            .into());
        }
        *state = StartupState::Ready(Box::new(snapshot));
        self.changed.notify_all();
        Ok(())
    }

    fn mark_failed(&self, error: &str) {
        if let Ok(mut state) = self.state.lock()
            && matches!(*state, StartupState::Starting)
        {
            *state = StartupState::Failed(error.to_string());
            self.changed.notify_all();
        }
    }

    fn mark_removed(&self, run_id: &str) {
        self.mark_failed(&format!(
            "codex run '{run_id}' was removed before startup completed"
        ));
    }

    fn lock(&self) -> Result<MutexGuard<'_, StartupState>, CliError> {
        self.state.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("codex run startup lock poisoned: {error}")).into()
        })
    }
}

#[derive(Clone, Default)]
pub(super) struct ActiveRuns {
    entries: Arc<Mutex<HashMap<String, ActiveRunEntry>>>,
}

impl ActiveRuns {
    pub(super) fn reserve(&self, run_id: String) -> Result<ActiveRunRegistration, CliError> {
        let startup = Arc::new(StartupSignal::new());
        match self.lock()?.entry(run_id.clone()) {
            Entry::Occupied(entry) => match entry.get() {
                ActiveRunEntry::Starting(startup) => {
                    Ok(ActiveRunRegistration::Waiting(ActiveRunWaiter {
                        run_id,
                        startup: Arc::clone(startup),
                    }))
                }
                ActiveRunEntry::Active(_) => Ok(ActiveRunRegistration::Active),
            },
            Entry::Vacant(entry) => {
                entry.insert(ActiveRunEntry::Starting(Arc::clone(&startup)));
                Ok(ActiveRunRegistration::Acquired(ActiveRunReservation {
                    entries: Arc::clone(&self.entries),
                    run_id,
                    startup,
                    finished: false,
                }))
            }
        }
    }

    pub(super) fn get(&self, run_id: &str) -> Result<ActiveRun, CliError> {
        match self.lock()?.get(run_id) {
            Some(ActiveRunEntry::Active(active)) => Ok(active.clone()),
            Some(ActiveRunEntry::Starting(_)) => Err(CliErrorKind::session_not_active(format!(
                "codex run '{run_id}' is still starting"
            ))
            .into()),
            None => Err(CliErrorKind::session_not_active(format!(
                "codex run '{run_id}' is not active"
            ))
            .into()),
        }
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
        let removed = entries.remove(run_id);
        drop(entries);
        if let Some(ActiveRunEntry::Starting(startup)) = removed {
            startup.mark_removed(run_id);
        }
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

    fn lock(&self) -> Result<MutexGuard<'_, HashMap<String, ActiveRunEntry>>, CliError> {
        lock_entries(&self.entries)
    }
}

fn lock_entries(
    entries: &Mutex<HashMap<String, ActiveRunEntry>>,
) -> Result<MutexGuard<'_, HashMap<String, ActiveRunEntry>>, CliError> {
    entries.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("codex active run lock poisoned: {error}")).into()
    })
}

fn lost_reservation_error(run_id: &str) -> CliError {
    CliErrorKind::session_agent_conflict(format!(
        "codex run '{run_id}' lost its startup reservation"
    ))
    .into()
}

#[cfg(test)]
mod tests;

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
