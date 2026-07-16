use std::path::Path;
use std::process::Command;
use std::str;
use std::thread;
use std::time::{Duration, Instant};

use super::super::crash_boundary::CrashBoundary;
use super::{
    CRASH_READINESS_TIMEOUT_SECONDS, CRASH_STABILIZATION_WINDOW_SECONDS, STATE_POLL_INTERVAL,
    checked, sudo, systemd_property, wait_for_state,
};

const PAUSE_SELECTION_ENV: &str = "HARNESS_REMOTE_SYSTEMD_E2E_PAUSE_AT";

pub(super) struct CrashCoordinator {
    service: String,
    recovery_service: String,
    recovery_timer: String,
    pid: Option<u32>,
    emergency_cleanup: bool,
}

impl CrashCoordinator {
    pub(super) fn start(
        controller_path: &Path,
        binary_path: &Path,
        unit: &str,
        env_path: &Path,
        candidate_path: &Path,
        boundary: CrashBoundary,
        occurrence: usize,
    ) -> Result<Self, String> {
        let service = boundary.transient_service_name(unit);
        let mut coordinator = Self {
            service: service.clone(),
            recovery_service: format!("{unit}-harness-recovery.service"),
            recovery_timer: format!("{unit}-harness-recovery.timer"),
            pid: None,
            emergency_cleanup: true,
        };
        let mut launch = sudo(["systemd-run", "--quiet"]);
        launch
            .arg(format!("--unit={service}"))
            .arg("--property=Type=exec")
            .arg("--property=TimeoutStopSec=2s")
            .arg(format!(
                "--setenv={PAUSE_SELECTION_ENV}={}",
                boundary.selector(occurrence)
            ))
            .arg("--")
            .arg(controller_path)
            .args(["upgrade", "--unit", unit])
            .arg("--candidate-path")
            .arg(candidate_path)
            .arg("--binary-path")
            .arg(binary_path)
            .arg("--env-file")
            .arg(env_path)
            .arg("--readiness-timeout-seconds")
            .arg(CRASH_READINESS_TIMEOUT_SECONDS)
            .arg("--stabilization-window-seconds")
            .arg(CRASH_STABILIZATION_WINDOW_SECONDS)
            .arg("--json");
        checked(launch, "start root upgrade coordinator")?;
        let pid = wait_for_coordinator_pid(&service)?;
        coordinator.pid = Some(pid);
        Ok(coordinator)
    }

    pub(super) const fn pid(&self) -> u32 {
        self.pid.expect("coordinator PID initialized after start")
    }

    pub(super) fn service(&self) -> &str {
        &self.service
    }

    pub(super) fn wait_until_paused(&self, timeout: Duration) -> Result<(), String> {
        wait_for_state(
            "upgrade coordinator to reach its crash boundary",
            timeout,
            || self.is_paused(),
        )
    }

    pub(super) fn assert_actual_root_upgrade_process(&self) -> Result<(), String> {
        let pid = self.pid();
        let status_path = format!("/proc/{pid}/status");
        let status = checked(
            sudo(["cat", status_path.as_str()]),
            "inspect root upgrade coordinator credentials",
        )?;
        let status = str::from_utf8(&status.stdout)
            .map_err(|error| format!("decode upgrade coordinator credentials: {error}"))?;
        let effective_uid = status
            .lines()
            .find_map(|line| line.strip_prefix("Uid:"))
            .and_then(|value| value.split_whitespace().nth(1));
        if effective_uid != Some("0") {
            return Err(format!(
                "upgrade coordinator PID {pid} did not run as root: effective UID {effective_uid:?}"
            ));
        }
        let command_path = format!("/proc/{pid}/cmdline");
        let command = checked(
            sudo(["cat", command_path.as_str()]),
            "inspect root upgrade coordinator command",
        )?;
        if command
            .stdout
            .split(|byte| *byte == 0)
            .any(|argument| argument == b"upgrade")
        {
            Ok(())
        } else {
            Err(format!(
                "captured PID {pid} was not the upgrade coordinator: {:?}",
                command.stdout
            ))
        }
    }

    pub(super) fn kill(&mut self) -> Result<(), String> {
        checked(
            sigkill_command(&self.service),
            "SIGKILL root upgrade coordinator",
        )?;
        self.emergency_cleanup = false;
        wait_for_state(
            "systemd to record coordinator SIGKILL",
            Duration::from_secs(10),
            || self.sigkill_was_recorded(),
        )
    }

    fn sigkill_was_recorded(&self) -> Result<bool, String> {
        let active_state = systemd_property(&self.service, "ActiveState")?;
        let main_code = systemd_property(&self.service, "ExecMainCode")?;
        Ok(matches!(active_state.as_str(), "failed" | "inactive")
            && systemd_property(&self.service, "Result")? == "signal"
            && matches!(main_code.as_str(), "2" | "killed")
            && systemd_property(&self.service, "ExecMainStatus")? == "9")
    }

    fn is_paused(&self) -> Result<bool, String> {
        let status_path = format!("/proc/{}/status", self.pid());
        let status = checked(
            sudo(["cat", status_path.as_str()]),
            "inspect paused upgrade coordinator",
        )?;
        let status = str::from_utf8(&status.stdout)
            .map_err(|error| format!("decode paused upgrade coordinator status: {error}"))?;
        let state = status
            .lines()
            .find_map(|line| line.strip_prefix("State:"))
            .and_then(|value| value.split_whitespace().next());
        Ok(state == Some("T"))
    }
}

impl Drop for CrashCoordinator {
    fn drop(&mut self) {
        if self.emergency_cleanup {
            let _ = sudo([
                "systemctl",
                "disable",
                "--now",
                self.recovery_timer.as_str(),
            ])
            .output();
            let _ = sudo(["systemctl", "stop", self.recovery_service.as_str()]).output();
        }
        let _ = sigkill_command(&self.service).output();
        let _ = sudo(["systemctl", "stop", self.service.as_str()]).output();
        let _ = sudo(["systemctl", "reset-failed", self.service.as_str()]).output();
    }
}

fn sigkill_command(service: &str) -> Command {
    let mut command = sudo(["systemctl", "kill", "--kill-whom=all", "--signal=SIGKILL"]);
    command.arg(service);
    command
}

fn wait_for_coordinator_pid(service: &str) -> Result<u32, String> {
    let started = Instant::now();
    let mut last_observation = String::new();
    while started.elapsed() < Duration::from_secs(10) {
        match systemd_property(service, "MainPID") {
            Ok(value) => {
                last_observation = value.clone();
                if let Ok(pid) = value.parse::<u32>()
                    && pid > 0
                {
                    return Ok(pid);
                }
            }
            Err(error) => last_observation = error,
        }
        thread::sleep(STATE_POLL_INTERVAL);
    }
    Err(format!(
        "root upgrade coordinator {service} did not expose MainPID: {last_observation}"
    ))
}
