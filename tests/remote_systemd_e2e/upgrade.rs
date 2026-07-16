use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::str;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::candidates::prepare_candidates;
use super::evidence::assert_corrupt_rollback_evidence;
use super::host::RemoteSystemdHost;

#[path = "upgrade/crash_coordinator.rs"]
mod crash_coordinator;
#[path = "upgrade/crash_matrix.rs"]
mod crash_matrix;

use crash_matrix::prove_runtime_permit_crash_matrix;

const READINESS_TIMEOUT_SECONDS: &str = "30";
const STABILIZATION_WINDOW_SECONDS: &str = "1";
const CRASH_READINESS_TIMEOUT_SECONDS: &str = "90";
const CRASH_STABILIZATION_WINDOW_SECONDS: &str = "30";
const CRASH_ARM_TIMEOUT: Duration = Duration::from_secs(90);
const CRASH_RECOVERY_TIMEOUT: Duration = Duration::from_secs(120);
const STATE_POLL_INTERVAL: Duration = Duration::from_millis(250);

pub struct RemoteSystemdUpgrade {
    valid_candidate_path: PathBuf,
    crash_candidate_path: PathBuf,
    spoofed_candidate_path: PathBuf,
    transaction_path: PathBuf,
}

impl RemoteSystemdUpgrade {
    pub fn new(binary_source: &Path, temp: &Path, unit: &str) -> Result<Self, String> {
        let valid_candidate_path = temp.join("valid-harness-candidate");
        let crash_candidate_path = temp.join("crash-harness-candidate");
        let spoofed_candidate_path = temp.join("spoofed-harness-candidate");
        prepare_candidates(
            binary_source,
            &valid_candidate_path,
            &crash_candidate_path,
            &spoofed_candidate_path,
        )?;
        Ok(Self {
            valid_candidate_path,
            crash_candidate_path,
            spoofed_candidate_path,
            transaction_path: PathBuf::from(format!("/var/lib/harness/remote-systemd/{unit}")),
        })
    }

    pub fn valid_candidate_path(&self) -> &Path {
        &self.valid_candidate_path
    }

    pub fn spoofed_candidate_path(&self) -> &Path {
        &self.spoofed_candidate_path
    }

    pub fn transaction_path(&self) -> &Path {
        &self.transaction_path
    }

    pub fn assert_database_corruption_marker(
        &self,
        state_path: &Path,
        service: &str,
        report: &Value,
    ) -> Result<(), String> {
        assert_corrupt_rollback_evidence(&self.transaction_path, state_path, service, report)
    }

    pub fn run(
        &self,
        controller_path: &Path,
        binary_path: &Path,
        unit: &str,
        env_path: &Path,
        candidate_path: &Path,
    ) -> Result<(i32, Value), String> {
        let mut command = sudo([controller_path.as_os_str()]);
        let upgrade_command = ["upgrade", "--unit", unit, "--json"];
        command.args(upgrade_command);
        command
            .arg("--candidate-path")
            .arg(candidate_path)
            .arg("--binary-path")
            .arg(binary_path)
            .arg("--env-file")
            .arg(env_path)
            .arg("--readiness-timeout-seconds")
            .arg(READINESS_TIMEOUT_SECONDS)
            .arg("--stabilization-window-seconds")
            .arg(STABILIZATION_WINDOW_SECONDS);
        json_output_with_exit_code(command, "upgrade remote systemd unit")
    }

    pub fn rollback(
        &self,
        controller_path: &Path,
        binary_path: &Path,
        unit: &str,
        env_path: &Path,
    ) -> Result<(i32, Value), String> {
        let mut command = sudo([controller_path.as_os_str()]);
        command.args(["rollback", "--unit", unit, "--confirm-data-loss", "--json"]);
        command
            .arg("--binary-path")
            .arg(binary_path)
            .arg("--env-file")
            .arg(env_path)
            .arg("--readiness-timeout-seconds")
            .arg(READINESS_TIMEOUT_SECONDS)
            .arg("--stabilization-window-seconds")
            .arg(STABILIZATION_WINDOW_SECONDS);
        json_output_with_exit_code(command, "rollback remote systemd unit")
    }

    fn prove_coordinator_crash_recovery(
        &self,
        controller_path: &Path,
        binary_path: &Path,
        unit: &str,
        env_path: &Path,
        state_path: &Path,
        prior_sha256: &str,
    ) -> Result<(), String> {
        prove_runtime_permit_crash_matrix(
            self,
            controller_path,
            binary_path,
            unit,
            env_path,
            state_path,
            prior_sha256,
        )
    }
}

impl RemoteSystemdHost {
    pub fn rollback(&self) -> Result<(i32, Value), String> {
        self.upgrade
            .rollback(
                &self.controller_path,
                &self.binary_path,
                &self.unit,
                &self.env_path,
            )
            .map_err(|error| self.with_diagnostics(error))
    }

    pub fn prove_upgrade_coordinator_crash_recovery(
        &self,
        prior_sha256: &str,
    ) -> Result<(), String> {
        self.upgrade
            .prove_coordinator_crash_recovery(
                &self.controller_path,
                &self.binary_path,
                &self.unit,
                &self.env_path,
                &self.state_path,
                prior_sha256,
            )
            .map_err(|error| self.with_diagnostics(error))
    }
}

fn wait_for_state<Probe>(label: &str, timeout: Duration, mut probe: Probe) -> Result<(), String>
where
    Probe: FnMut() -> Result<bool, String>,
{
    let started = Instant::now();
    let mut last_error = None;
    loop {
        match probe() {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => last_error = Some(error),
        }
        if started.elapsed() >= timeout {
            return Err(last_error.map_or_else(
                || format!("timed out waiting for {label}"),
                |error| format!("timed out waiting for {label}: {error}"),
            ));
        }
        thread::sleep(STATE_POLL_INTERVAL);
    }
}

fn systemd_property(service: &str, property: &str) -> Result<String, String> {
    let mut command = Command::new("systemctl");
    command.args(["show", "--value", "--property", property, service]);
    let output = checked(command, &format!("read {service} {property}"))?;
    stdout(&output, &format!("{service} {property}")).map(|value| value.trim().to_string())
}

fn running_binary_digest(service: &str) -> Result<String, String> {
    let pid = systemd_property(service, "MainPID")?
        .parse::<u32>()
        .map_err(|error| format!("parse {service} MainPID: {error}"))?;
    if pid == 0 {
        return Err(format!("{service} MainPID is zero"));
    }
    file_digest(
        &PathBuf::from(format!("/proc/{pid}/exe")),
        &format!("{service} running binary"),
    )
}

fn recovery_service_name(unit: &str) -> String {
    format!("{unit}-harness-recovery.service")
}

fn recovery_timer_name(unit: &str) -> String {
    format!("{unit}-harness-recovery.timer")
}

pub fn file_digest(path: &Path, label: &str) -> Result<String, String> {
    let output = checked(
        sudo([OsStr::new("sha256sum"), path.as_os_str()]),
        &format!("hash {label}"),
    )?;
    stdout(&output, &format!("{label} digest")).and_then(|value| {
        value
            .split_whitespace()
            .next()
            .map(str::to_string)
            .ok_or_else(|| format!("sha256sum omitted {label} digest"))
    })
}

fn json_output_with_exit_code(mut command: Command, action: &str) -> Result<(i32, Value), String> {
    command.env("LC_ALL", "C");
    let output = command
        .output()
        .map_err(|error| format!("{action}: {error}"))?;
    let exit_code = output
        .status
        .code()
        .ok_or_else(|| format!("{action} terminated by signal"))?;
    let stdout = stdout(&output, action)?;
    let value = serde_json::from_str(stdout.trim()).map_err(|error| {
        format!(
            "decode {action} JSON: {error}; stdout={stdout}; stderr={}",
            String::from_utf8_lossy(&output.stderr)
        )
    })?;
    Ok((exit_code, value))
}

fn checked(mut command: Command, action: &str) -> Result<Output, String> {
    command.env("LC_ALL", "C");
    let output = command
        .output()
        .map_err(|error| format!("{action}: {error}"))?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(format!(
            "{action} exited with {}; stdout={}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

fn stdout<'a>(output: &'a Output, action: &str) -> Result<&'a str, String> {
    str::from_utf8(&output.stdout).map_err(|error| format!("decode {action} stdout: {error}"))
}

fn sudo<I, S>(args: I) -> Command
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = Command::new("sudo");
    command.arg("-n").args(args);
    command
}
