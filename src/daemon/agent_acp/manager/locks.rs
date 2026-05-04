use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::time::Instant;

use super::{AcpAgentManagerHandle, ActiveAcpProcess, ActiveAcpSession, DaemonDb};
use crate::errors::{CliError, CliErrorKind};

type SessionRegistry = BTreeMap<String, Arc<ActiveAcpSession>>;
type ProcessRegistry = BTreeMap<String, Arc<ActiveAcpProcess>>;

impl AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) fn process_lifecycle_guard(
        &self,
    ) -> Result<MutexGuard<'_, ()>, CliError> {
        lock_named(&self.state.process_lifecycle, "ACP process lifecycle lock")
    }

    pub(in crate::daemon::agent_acp) fn sessions_guard(
        &self,
    ) -> Result<MutexGuard<'_, SessionRegistry>, CliError> {
        lock_named(&self.state.sessions, "ACP sessions lock")
    }

    pub(in crate::daemon::agent_acp) fn processes_guard(
        &self,
    ) -> Result<MutexGuard<'_, ProcessRegistry>, CliError> {
        lock_named(&self.state.processes, "ACP processes lock")
    }

    pub(in crate::daemon::agent_acp) fn process_key_backoff_until_guard(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, Instant>>, CliError> {
        lock_named(
            &self.state.process_key_backoff_until,
            "ACP process key backoff lock",
        )
    }

    pub(in crate::daemon::agent_acp) fn process_key_failures_guard(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, u32>>, CliError> {
        lock_named(
            &self.state.process_key_failures,
            "ACP process key failures lock",
        )
    }

    pub(in crate::daemon::agent_acp) fn quarantined_process_keys_guard(
        &self,
    ) -> Result<MutexGuard<'_, BTreeSet<String>>, CliError> {
        lock_named(
            &self.state.quarantined_process_keys,
            "ACP quarantined process keys lock",
        )
    }

    pub(in crate::daemon::agent_acp) fn daemon_db_guard(
        db: &Arc<Mutex<DaemonDb>>,
    ) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
        lock_named(db, "daemon database lock")
    }
}

fn lock_named<'a, T>(mutex: &'a Mutex<T>, label: &str) -> Result<MutexGuard<'a, T>, CliError> {
    mutex.lock().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "{label} poisoned: {error}"
        )))
    })
}
