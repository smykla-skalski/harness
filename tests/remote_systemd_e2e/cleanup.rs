use std::ffi::OsStr;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::str;

use super::crash_boundary::CrashBoundary;
use super::systemd_assertions::{assert_binary_claim_absent, assert_uninstalled};

const RUNTIME_PERMIT_FILE: &str = "90-harness-inhibit.conf";
const RUNTIME_TOKEN_PREFIX: &str = ".harness-start-permit-";
const ARMED_TRANSACTION_ERROR: &str =
    "refusing systemd install or uninstall while a transaction is armed";
const PENDING_GENERATION_ERROR: &str =
    "refusing systemd install or uninstall while pending generation requires lifecycle recovery";
const INTERRUPTED_ROTATION_ERROR: &str = concat!(
    "refusing systemd install or uninstall while interrupted generation rotation ",
    "requires lifecycle recovery"
);

struct RuntimeTokenArtifact {
    directory: PathBuf,
    token: PathBuf,
}

pub(super) struct SystemdCleanup {
    cleanup_binary: PathBuf,
    unit: String,
    environment_path: PathBuf,
    transaction_path: PathBuf,
    units: Vec<(String, bool)>,
    crash_services: Vec<String>,
    recovery_service: String,
    recovery_timer: String,
    files: Vec<PathBuf>,
    directories: Vec<PathBuf>,
    runtime_permit_directory: PathBuf,
}

impl SystemdCleanup {
    pub(super) fn new(
        cleanup_controller: &Path,
        unit: &str,
        unit_path: &Path,
        environment_path: &Path,
        ca_path: &Path,
        binary_path: &Path,
        private_state_path: &Path,
        transaction_path: &Path,
    ) -> Result<Self, String> {
        let binary_parent = binary_path
            .parent()
            .ok_or_else(|| "systemd E2E binary path has no parent".to_string())?;
        let recovery_service = format!("{unit}-harness-recovery.service");
        let recovery_timer = format!("{unit}-harness-recovery.timer");
        let crash_services = CrashBoundary::ALL
            .into_iter()
            .map(|boundary| boundary.transient_service_name(unit))
            .collect::<Vec<_>>();
        let mut units = vec![
            (format!("{unit}.service"), true),
            (recovery_service.clone(), false),
            (recovery_timer.clone(), true),
        ];
        units.extend(
            crash_services
                .iter()
                .cloned()
                .map(|service| (service, false)),
        );
        let recovery_service_path = unit_path.with_file_name(&recovery_service);
        let recovery_timer_path = unit_path.with_file_name(&recovery_timer);
        let inhibitor_directory = unit_path.with_file_name(format!("{unit}.service.d"));
        let runtime_permit_directory =
            Path::new("/run/systemd/system.control").join(format!("{unit}.service.d"));
        Ok(Self {
            cleanup_binary: cleanup_controller.to_path_buf(),
            unit: unit.to_string(),
            environment_path: environment_path.to_path_buf(),
            transaction_path: transaction_path.to_path_buf(),
            units,
            crash_services,
            recovery_service,
            recovery_timer,
            files: vec![
                unit_path.to_path_buf(),
                environment_path.to_path_buf(),
                ca_path.to_path_buf(),
                cleanup_controller.to_path_buf(),
                binary_path.to_path_buf(),
                recovery_service_path,
                recovery_timer_path,
                transaction_path.join("state-restore-reserve"),
                binary_parent.join(format!(".harness-{unit}-binary-reserve")),
            ],
            directories: vec![
                inhibitor_directory,
                binary_parent.join(format!(".harness-{unit}-binary-inode-reserve")),
                private_state_path.to_path_buf(),
                PathBuf::from(format!("/var/lib/{unit}")),
                transaction_path.to_path_buf(),
            ],
            runtime_permit_directory,
        })
    }

    pub(super) fn run(&self) -> Result<(), String> {
        stop_loaded_unit(&self.recovery_timer, true)?;
        stop_loaded_unit(&self.recovery_service, false)?;
        kill_paused_coordinators(&self.crash_services);
        for (unit, disable) in &self.units {
            if unit != &self.recovery_timer && unit != &self.recovery_service {
                stop_loaded_unit(unit, *disable)?;
            }
        }
        self.release_managed_install()?;
        assert_binary_claim_absent(&self.unit)?;
        remove_paths("-f", &self.files, "remove systemd E2E files")?;
        cleanup_runtime_start_permit(&self.runtime_permit_directory)?;
        remove_paths("-rf", &self.directories, "remove systemd E2E directories")?;
        checked(
            sudo(["systemctl", "daemon-reload"]),
            "reload systemd after E2E cleanup",
        )?;
        let units = self
            .units
            .iter()
            .map(|(unit, _)| unit.as_str())
            .collect::<Vec<_>>();
        let paths = self
            .files
            .iter()
            .chain(&self.directories)
            .chain(std::iter::once(&self.runtime_permit_directory))
            .map(PathBuf::as_path)
            .collect::<Vec<_>>();
        assert_uninstalled(&units, &paths)
    }

    pub(super) fn best_effort(&self) {
        stop_unit_best_effort(&self.recovery_timer, true);
        stop_unit_best_effort(&self.recovery_service, false);
        kill_paused_coordinators(&self.crash_services);
        for (unit, disable) in &self.units {
            if unit != &self.recovery_timer && unit != &self.recovery_service {
                stop_unit_best_effort(unit, *disable);
            }
        }
        if self.release_managed_install().is_err()
            || assert_binary_claim_absent(&self.unit).is_err()
        {
            return;
        }
        let _ = remove_paths("-f", &self.files, "best-effort file cleanup");
        let _ = cleanup_runtime_start_permit(&self.runtime_permit_directory);
        let _ = remove_paths("-rf", &self.directories, "best-effort directory cleanup");
        let _ = sudo(["systemctl", "daemon-reload"]).output();
    }

    fn release_managed_install(&self) -> Result<(), String> {
        release_managed_install_with(
            || self.uninstall_managed_unit(),
            || self.disarm_interrupted_transaction(),
        )
    }

    fn disarm_interrupted_transaction(&self) -> Result<(), String> {
        remove_paths(
            "-rf",
            std::slice::from_ref(&self.transaction_path),
            "remove interrupted systemd E2E transaction",
        )
    }

    fn uninstall_managed_unit(&self) -> Result<(), String> {
        let mut command = sudo([self.cleanup_binary.as_os_str()]);
        command.args(["uninstall", "--unit", &self.unit, "--json"]);
        command.arg("--env-file").arg(&self.environment_path);
        checked(command, "release systemd E2E managed installation").map(|_| ())
    }
}

fn release_managed_install_with<Uninstall, Disarm>(
    mut uninstall: Uninstall,
    disarm: Disarm,
) -> Result<(), String>
where
    Uninstall: FnMut() -> Result<(), String>,
    Disarm: FnOnce() -> Result<(), String>,
{
    let initial_error = match uninstall() {
        Ok(()) => return Ok(()),
        Err(error) => error,
    };
    if !transaction_cleanup_required(&initial_error) {
        return Err(initial_error);
    }
    disarm().map_err(|error| {
        format!(
            "release systemd E2E managed installation failed: {initial_error}; removing interrupted transaction before retry also failed: {error}"
        )
    })?;
    uninstall().map_err(|error| {
        format!(
            "release systemd E2E managed installation failed: {initial_error}; retry after removing interrupted transaction failed: {error}"
        )
    })
}

fn transaction_cleanup_required(error: &str) -> bool {
    [
        ARMED_TRANSACTION_ERROR,
        PENDING_GENERATION_ERROR,
        INTERRUPTED_ROTATION_ERROR,
    ]
    .iter()
    .any(|message| error.contains(message))
}

fn kill_paused_coordinators(services: &[String]) {
    for service in services {
        let mut command = sudo(["systemctl", "kill", "--kill-whom=all", "--signal=SIGKILL"]);
        let _ = command.arg(service).output();
    }
}

fn stop_unit_best_effort(unit: &str, disable: bool) {
    let verb = if disable { "disable" } else { "stop" };
    let mut command = sudo(["systemctl", verb]);
    if disable {
        command.arg("--now");
    }
    let _ = command.arg(unit).output();
    let _ = sudo(["systemctl", "reset-failed", unit]).output();
}

fn cleanup_runtime_start_permit(directory: &Path) -> Result<(), String> {
    if !is_real_directory(directory)? {
        return Ok(());
    }
    let permit = directory.join(RUNTIME_PERMIT_FILE);
    let token_artifacts = runtime_token_artifacts(directory);
    let permit_cleanup = remove_paths("-f", &[permit], "remove systemd E2E runtime start permit");
    let token_cleanup = token_artifacts.and_then(|artifacts| {
        let (directories, tokens): (Vec<_>, Vec<_>) = artifacts
            .into_iter()
            .map(|artifact| (artifact.directory, artifact.token))
            .unzip();
        let token_files = remove_paths(
            "-f",
            &tokens,
            "remove systemd E2E runtime start-permit tokens",
        );
        let token_directories = remove_empty_runtime_directories(&directories);
        token_files.and(token_directories)
    });
    let directory_cleanup = remove_empty_runtime_directory(directory);
    permit_cleanup.and(token_cleanup).and(directory_cleanup)
}

fn runtime_token_artifacts(directory: &Path) -> Result<Vec<RuntimeTokenArtifact>, String> {
    let mut artifacts = Vec::new();
    for entry in fs::read_dir(directory)
        .map_err(|error| format!("inspect systemd E2E runtime permit directory: {error}"))?
    {
        let entry = entry.map_err(|error| {
            format!("inspect systemd E2E runtime permit directory entry: {error}")
        })?;
        let file_type = entry.file_type().map_err(|error| {
            format!(
                "inspect systemd E2E runtime permit entry {}: {error}",
                entry.path().display()
            )
        })?;
        let name = entry.file_name();
        if file_type.is_dir() && is_runtime_token_directory_name(&name) {
            let directory = entry.path();
            let mut token_name = name;
            token_name.push(".token");
            artifacts.push(RuntimeTokenArtifact {
                token: directory.join(token_name),
                directory,
            });
        }
    }
    Ok(artifacts)
}

fn is_runtime_token_directory_name(name: &OsStr) -> bool {
    let Some(identity) = name
        .to_str()
        .and_then(|name| name.strip_prefix(RUNTIME_TOKEN_PREFIX))
    else {
        return false;
    };
    identity.len() == 32
        && identity
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn is_real_directory(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(metadata.is_dir() && !metadata.file_type().is_symlink()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!(
            "inspect systemd E2E runtime permit directory {}: {error}",
            path.display()
        )),
    }
}

fn remove_empty_runtime_directory(path: &Path) -> Result<(), String> {
    remove_empty_runtime_directories(&[path.to_path_buf()])
}

fn remove_empty_runtime_directories(paths: &[PathBuf]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut command = sudo(["rmdir", "--ignore-fail-on-non-empty"]);
    command.args(paths);
    checked(
        command,
        "remove empty systemd E2E runtime start-permit directories",
    )?;
    Ok(())
}

fn stop_loaded_unit(unit: &str, disable: bool) -> Result<(), String> {
    if systemd_property(unit, "LoadState")? == "not-found" {
        return Ok(());
    }
    let action = if disable { "disable" } else { "stop" };
    let mut command = sudo(["systemctl", action]);
    if disable {
        command.arg("--now");
    }
    command.arg(unit);
    if let Err(error) = checked(command, &format!("{action} systemd E2E unit {unit}")) {
        if systemd_property(unit, "LoadState")? == "not-found" {
            return Ok(());
        }
        return Err(error);
    }
    reset_failed_unit(unit)
}

fn reset_failed_unit(unit: &str) -> Result<(), String> {
    let action = format!("reset systemd E2E unit {unit}");
    let mut command = sudo([
        "/usr/bin/env",
        "LC_ALL=C",
        "SYSTEMD_COLORS=0",
        "SYSTEMD_LOG_COLOR=0",
        "SYSTEMD_LOG_LEVEL=info",
        "SYSTEMD_LOG_LOCATION=0",
        "SYSTEMD_LOG_TARGET=console",
        "SYSTEMD_LOG_TID=0",
        "SYSTEMD_LOG_TIME=0",
        "SYSTEMD_URLIFY=0",
        "systemctl",
        "reset-failed",
        unit,
    ]);
    let output = command
        .output()
        .map_err(|error| format!("{action}: {error}"))?;
    if output.status.success() || reset_failed_reports_unloaded(unit, &output.stderr) {
        Ok(())
    } else {
        Err(format!(
            "{action} exited with {}; stdout={}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

fn reset_failed_reports_unloaded(unit: &str, stderr: &[u8]) -> bool {
    let expected = reset_failed_unloaded_message(unit);
    String::from_utf8_lossy(stderr).trim() == expected
}

fn reset_failed_unloaded_message(unit: &str) -> String {
    let action = format!("Failed to reset failed state of unit {unit}:");
    let detail = format!("Unit {unit} not loaded.");
    format!("{action} {detail}")
}

fn systemd_property(unit: &str, property: &str) -> Result<String, String> {
    let mut command = Command::new("systemctl");
    command.args(["show", "--value", "--property", property, unit]);
    let output = checked(command, &format!("read {unit} {property}"))?;
    str::from_utf8(&output.stdout)
        .map(|value| value.trim().to_string())
        .map_err(|error| format!("decode {unit} {property}: {error}"))
}

fn remove_paths(option: &str, paths: &[PathBuf], action: &str) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut command = sudo(["rm", option]);
    command.args(paths);
    checked(command, action)?;
    Ok(())
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

fn sudo<I, S>(args: I) -> Command
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = Command::new("sudo");
    command.arg("-n").args(args);
    command
}

#[cfg(test)]
#[path = "cleanup/tests.rs"]
mod tests;
