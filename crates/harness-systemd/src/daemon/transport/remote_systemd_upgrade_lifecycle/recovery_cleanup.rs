#[cfg(all(target_os = "linux", not(test)))]
use std::fs::File;
use std::io::ErrorKind;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use fs_err as fs;
#[cfg(all(target_os = "linux", not(test)))]
use nix::unistd::syncfs;

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::automation::{
    load_recovery_arm, remove_recovery_unit_files_at, systemctl_checked,
    validate_recovery_unit_files_at,
};
use super::files::{io_error, regular_file_metadata, remove_file_if_exists, sync_directory};
use super::model::RECOVERY_CONTROLLER_FILE;
use super::systemd_reset::reset_failed_units;

struct RecoveryUnit {
    name: String,
    path: PathBuf,
    present: bool,
    kind: RecoveryUnitKind,
}

#[derive(Clone, Copy)]
enum RecoveryUnitKind {
    Service,
    Timer,
}

struct RecoveryObservation {
    load_state: String,
    active_state: String,
    main_pid: u32,
    fragment_path: String,
    drop_in_paths: String,
    unit_file_state: String,
}

pub(crate) fn cleanup_recovery_artifacts<RunSystemctl>(
    unit: &str,
    unit_path: &Path,
    store_path: &Path,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    if load_recovery_arm(store_path)?.is_some() {
        return Err(io_error(format!(
            "refusing to uninstall {unit} while a systemd transaction is armed"
        )));
    }
    validate_recovery_unit_files_at(unit, unit_path, store_path)?;
    let service = recovery_unit(unit, unit_path, "service")?;
    let timer = recovery_unit(unit, unit_path, "timer")?;
    let controller_path = store_path.join(RECOVERY_CONTROLLER_FILE);
    let controller_present = validate_controller(&controller_path)?;
    let service_before = observe_recovery_unit(&service, run_systemctl)?;
    let timer_before = observe_recovery_unit(&timer, run_systemctl)?;

    if !service.present && !timer.present {
        return cleanup_stale_or_absent(
            &service,
            &timer,
            &service_before,
            &timer_before,
            &controller_path,
            controller_present,
            run_systemctl,
        );
    }

    require_owned_or_absent(&service, &service_before, false)?;
    require_owned_or_absent(&timer, &timer_before, true)?;
    require_quiescent(&service.name, &service_before)?;
    require_timer_safe_before_disable(&timer.name, &timer_before)?;
    if timer.present {
        systemctl_checked(
            run_systemctl,
            &[
                "disable".to_string(),
                "--now".to_string(),
                "--".to_string(),
                timer.name.clone(),
            ],
        )?;
    }
    let reset_units = [
        service.present.then(|| service.name.clone()),
        timer.present.then(|| timer.name.clone()),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();
    reset_failed_units(&reset_units, run_systemctl)?;
    sync_systemd_unit_filesystem(unit_path)?;

    let service_after = observe_recovery_unit(&service, run_systemctl)?;
    let timer_after = observe_recovery_unit(&timer, run_systemctl)?;
    require_owned_or_absent(&service, &service_after, false)?;
    require_owned_or_absent(&timer, &timer_after, true)?;
    require_inactive(&service.name, &service_after)?;
    require_inactive(&timer.name, &timer_after)?;
    if timer.present && timer_after.unit_file_state != "disabled" {
        return Err(io_error(format!(
            "recovery timer {} remained enabled after disable (UnitFileState={})",
            timer.name, timer_after.unit_file_state
        )));
    }

    remove_recovery_unit_files_at(unit, unit_path, store_path)?;
    sync_systemd_unit_filesystem(unit_path)?;
    remove_controller(&controller_path, controller_present, store_path)?;
    reload_and_require_absent(&service, &timer, run_systemctl)
}

fn cleanup_stale_or_absent<RunSystemctl>(
    service: &RecoveryUnit,
    timer: &RecoveryUnit,
    service_before: &RecoveryObservation,
    timer_before: &RecoveryObservation,
    controller_path: &Path,
    controller_present: bool,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let both_absent = observation_is_absent(service_before) && observation_is_absent(timer_before);
    if both_absent {
        return remove_controller(
            controller_path,
            controller_present,
            controller_path
                .parent()
                .ok_or_else(|| io_error("recovery controller path has no parent"))?,
        );
    }
    require_stale_unit_ready(service, service_before, false)?;
    require_stale_unit_ready(timer, timer_before, true)?;
    remove_controller(
        controller_path,
        controller_present,
        controller_path
            .parent()
            .ok_or_else(|| io_error("recovery controller path has no parent"))?,
    )?;
    reload_and_require_absent(service, timer, run_systemctl)
}

fn recovery_unit(unit: &str, unit_path: &Path, suffix: &str) -> Result<RecoveryUnit, CliError> {
    let name = format!("{unit}-harness-recovery.{suffix}");
    let path = unit_path.with_file_name(&name);
    let kind = if suffix == "timer" {
        RecoveryUnitKind::Timer
    } else {
        RecoveryUnitKind::Service
    };
    Ok(RecoveryUnit {
        name,
        present: regular_file_exists(&path)?,
        path,
        kind,
    })
}

fn regular_file_exists(path: &Path) -> Result<bool, CliError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error(format!("inspect {}: {error}", path.display()))),
    }
}

fn validate_controller(path: &Path) -> Result<bool, CliError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(_) => regular_file_metadata(path)?,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(io_error(format!(
                "inspect recovery controller {}: {error}",
                path.display()
            )));
        }
    };
    if metadata.uid() != trusted_uid() || metadata.mode() & 0o022 != 0 {
        return Err(io_error(format!(
            "recovery controller {} must be trusted-owner and not group or world writable",
            path.display()
        )));
    }
    if metadata.mode() & 0o111 == 0 {
        return Err(io_error(format!(
            "recovery controller {} must be executable",
            path.display()
        )));
    }
    Ok(true)
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    uzers::get_current_uid()
}

fn observe_recovery_unit<RunSystemctl>(
    unit: &RecoveryUnit,
    run_systemctl: &RunSystemctl,
) -> Result<RecoveryObservation, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let mut args = vec![
        "show".to_string(),
        "--property=LoadState".to_string(),
        "--property=ActiveState".to_string(),
        "--property=FragmentPath".to_string(),
        "--property=DropInPaths".to_string(),
        "--property=UnitFileState".to_string(),
    ];
    if matches!(unit.kind, RecoveryUnitKind::Service) {
        args.push("--property=MainPID".to_string());
    }
    args.extend(["--".to_string(), unit.name.clone()]);
    let output = run_systemctl(&args)?;
    if output.exit_code != 0 {
        return Err(io_error(format!(
            "inspect recovery unit {}: {}",
            unit.name,
            output.stderr.trim()
        )));
    }
    let main_pid = match unit.kind {
        RecoveryUnitKind::Service => required_property(&output.stdout, "MainPID")?
            .parse::<u32>()
            .map_err(|error| io_error(format!("parse recovery unit MainPID: {error}")))?,
        RecoveryUnitKind::Timer => {
            require_property_absent(&output.stdout, "MainPID")?;
            0
        }
    };
    Ok(RecoveryObservation {
        load_state: required_property(&output.stdout, "LoadState")?.to_string(),
        active_state: required_property(&output.stdout, "ActiveState")?.to_string(),
        main_pid,
        fragment_path: required_property(&output.stdout, "FragmentPath")?.to_string(),
        drop_in_paths: required_property(&output.stdout, "DropInPaths")?.to_string(),
        unit_file_state: required_property(&output.stdout, "UnitFileState")?.to_string(),
    })
}

fn require_owned_or_absent(
    unit: &RecoveryUnit,
    observation: &RecoveryObservation,
    timer: bool,
) -> Result<(), CliError> {
    if unit.present {
        require_exact_source(unit, observation)
    } else if observation_is_absent(observation) {
        Ok(())
    } else {
        require_stale_unit_ready(unit, observation, timer)
    }
}

fn require_exact_source(
    unit: &RecoveryUnit,
    observation: &RecoveryObservation,
) -> Result<(), CliError> {
    if observation.load_state == "loaded"
        && Path::new(&observation.fragment_path) == unit.path
        && observation.drop_in_paths.is_empty()
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "recovery unit {} has unexpected effective sources (LoadState={}, FragmentPath={}, DropInPaths={})",
            unit.name, observation.load_state, observation.fragment_path, observation.drop_in_paths
        )))
    }
}

fn require_quiescent(name: &str, observation: &RecoveryObservation) -> Result<(), CliError> {
    if matches!(observation.active_state.as_str(), "inactive" | "failed")
        && observation.main_pid == 0
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "recovery unit {name} may be running (ActiveState={}, MainPID={})",
            observation.active_state, observation.main_pid
        )))
    }
}

fn require_timer_safe_before_disable(
    name: &str,
    observation: &RecoveryObservation,
) -> Result<(), CliError> {
    if matches!(
        observation.active_state.as_str(),
        "active" | "inactive" | "failed"
    ) && observation.main_pid == 0
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "recovery timer {name} has unsafe state (ActiveState={}, MainPID={})",
            observation.active_state, observation.main_pid
        )))
    }
}

fn require_inactive(name: &str, observation: &RecoveryObservation) -> Result<(), CliError> {
    if observation.active_state == "inactive" && observation.main_pid == 0 {
        Ok(())
    } else {
        Err(io_error(format!(
            "recovery unit {name} did not become inactive (ActiveState={}, MainPID={})",
            observation.active_state, observation.main_pid
        )))
    }
}

fn require_stale_unit_ready(
    unit: &RecoveryUnit,
    observation: &RecoveryObservation,
    timer: bool,
) -> Result<(), CliError> {
    if observation.load_state != "loaded"
        || Path::new(&observation.fragment_path) != unit.path
        || !observation.drop_in_paths.is_empty()
    {
        return Err(io_error(format!(
            "refusing to reload untracked stale recovery unit {}",
            unit.name
        )));
    }
    require_inactive(&unit.name, observation)?;
    if timer && observation.unit_file_state != "disabled" {
        return Err(io_error(format!(
            "stale recovery timer {} is not disabled",
            unit.name
        )));
    }
    Ok(())
}

fn remove_controller(path: &Path, present: bool, store_path: &Path) -> Result<(), CliError> {
    if present {
        remove_file_if_exists(path)?;
        sync_directory(store_path)?;
    }
    Ok(())
}

fn reload_and_require_absent<RunSystemctl>(
    service: &RecoveryUnit,
    timer: &RecoveryUnit,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    systemctl_checked(run_systemctl, &["daemon-reload".to_string()])?;
    let service_after = observe_recovery_unit(service, run_systemctl)?;
    let timer_after = observe_recovery_unit(timer, run_systemctl)?;
    if observation_is_absent(&service_after) && observation_is_absent(&timer_after) {
        Ok(())
    } else {
        Err(io_error(format!(
            "recovery units for {} remained loaded after cleanup",
            service.name.trim_end_matches("-harness-recovery.service")
        )))
    }
}

fn observation_is_absent(observation: &RecoveryObservation) -> bool {
    observation.load_state == "not-found"
        && observation.active_state == "inactive"
        && observation.main_pid == 0
        && observation.fragment_path.is_empty()
        && observation.drop_in_paths.is_empty()
        && observation.unit_file_state.is_empty()
}

fn required_property<'a>(stdout: &'a str, name: &str) -> Result<&'a str, CliError> {
    let values = stdout
        .lines()
        .filter_map(|line| line.split_once('=').filter(|(key, _)| *key == name))
        .map(|(_, value)| value)
        .collect::<Vec<_>>();
    let [value] = values.as_slice() else {
        return Err(io_error(format!(
            "systemctl show must return exactly one {name} property, found {}",
            values.len()
        )));
    };
    Ok(value)
}

fn require_property_absent(stdout: &str, name: &str) -> Result<(), CliError> {
    if stdout
        .lines()
        .all(|line| line.split_once('=').is_none_or(|(key, _)| key != name))
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemctl show unexpectedly returned {name} for a timer"
        )))
    }
}

fn sync_systemd_unit_filesystem(unit_path: &Path) -> Result<(), CliError> {
    let parent = unit_path
        .parent()
        .ok_or_else(|| io_error("systemd unit path has no parent"))?;
    #[cfg(all(target_os = "linux", not(test)))]
    {
        let directory = File::open(parent).map_err(|error| {
            io_error(format!(
                "open systemd unit filesystem {}: {error}",
                parent.display()
            ))
        })?;
        syncfs(&directory).map_err(|error| {
            io_error(format!(
                "sync systemd unit filesystem {}: {error}",
                parent.display()
            ))
        })
    }
    #[cfg(any(not(target_os = "linux"), test))]
    {
        sync_directory(parent)
    }
}

#[cfg(test)]
#[path = "recovery_cleanup/tests.rs"]
mod tests;
