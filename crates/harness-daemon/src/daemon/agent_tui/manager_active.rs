use std::collections::BTreeMap;
use std::sync::{Arc, MutexGuard};

use harness_kernel::errors::{CliError, CliErrorKind};

use super::manager::{ActiveAgentTui, AgentTuiManagerHandle, LiveRefreshWake};
use harness_daemon_managed_agents::{AgentTuiProcess, lock};

impl AgentTuiManagerHandle {
    pub(super) fn active(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, ActiveAgentTui>>, CliError> {
        lock(&self.state.active, "terminal agent active process map")
    }

    pub(crate) fn active_process(&self, tui_id: &str) -> Result<Arc<AgentTuiProcess>, CliError> {
        self.active_tui(tui_id)?.process.ok_or_else(|| {
            CliErrorKind::session_not_active(format!("terminal agent '{tui_id}' is not active"))
                .into()
        })
    }

    pub(crate) fn active_tui(&self, tui_id: &str) -> Result<ActiveAgentTui, CliError> {
        self.active()?.get(tui_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!("terminal agent '{tui_id}' is not active"))
                .into()
        })
    }

    pub(crate) fn remove_active(
        &self,
        tui_id: &str,
    ) -> Result<Option<Arc<AgentTuiProcess>>, CliError> {
        let removed = self.active()?.remove(tui_id);
        if let Some(active) = &removed {
            active.stop();
        }
        Ok(removed.and_then(|active| active.process))
    }

    pub(super) fn remove_active_for_refresh(
        &self,
        tui_id: &str,
        refresh_wake: &Arc<LiveRefreshWake>,
    ) -> Result<(), CliError> {
        let removed = {
            let mut active = self.active()?;
            match active.get(tui_id) {
                Some(current) if Arc::ptr_eq(&current.refresh_wake, refresh_wake) => {
                    active.remove(tui_id)
                }
                _ => None,
            }
        };
        if let Some(active) = removed {
            active.stop();
        }
        Ok(())
    }
}
