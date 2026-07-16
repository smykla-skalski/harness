use crate::daemon::transport::remote_systemd_upgrade_lifecycle::{
    RemoteSystemdHealthReport, RemoteSystemdOperationPlan,
};
use crate::errors::{CliError, CliErrorKind};

use super::{ScriptedSystemd, installed_is_candidate};

impl ScriptedSystemd<'_> {
    pub(in super::super) fn verify<RunSystemctl>(
        &self,
        _plan: &RemoteSystemdOperationPlan,
        expected_sha256: &str,
        _run_systemctl: &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError> {
        let candidate_active = installed_is_candidate(&self.fixture.binary);
        let state = self.state.borrow();
        assert!(
            !state.panic_on_candidate_health || !candidate_active,
            "simulated coordinator crash during candidate health verification"
        );
        if !state.active {
            return Err(CliErrorKind::workflow_io(
                "managed systemd service must be active before upgrade".to_string(),
            )
            .into());
        }
        if self.fail_candidate_health && candidate_active {
            return Err(CliErrorKind::workflow_io(
                "forced candidate readiness failure after database migration".to_string(),
            )
            .into());
        }
        if state.fail_old_health && state.starts > 0 && !candidate_active {
            return Err(CliErrorKind::workflow_io(
                "forced restored-generation health failure".to_string(),
            )
            .into());
        }
        Ok(RemoteSystemdHealthReport {
            status: "ready".to_string(),
            attempts: 1,
            main_pid: 4242,
            n_restarts: 0,
            active_state: "active".to_string(),
            sub_state: "running".to_string(),
            observed_sha256: expected_sha256.to_string(),
        })
    }
}
