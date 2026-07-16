use std::fs::{self, File};
use std::io::ErrorKind;
use std::path::Path;

#[cfg(all(target_os = "linux", not(test)))]
use nix::unistd::syncfs;

use crate::daemon::transport::remote_systemd_cgroup::{
    ValidatedControlGroup, cgroup_events_file_at, validate_control_group_before_stop,
};
use crate::errors::{CliError, CliErrorKind};

use super::super::{RemoteSystemdCommandOutput, required_systemd_property};
use super::UninstallObservation;

pub(super) fn observe_uninstall_service<RunSystemctl>(
    service: &str,
    phase: &str,
    run_systemctl: &RunSystemctl,
) -> Result<UninstallObservation, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = run_systemctl(&[
        "show".to_string(),
        "--property=Id".to_string(),
        "--property=Names".to_string(),
        "--property=LoadState".to_string(),
        "--property=NeedDaemonReload".to_string(),
        "--property=FragmentPath".to_string(),
        "--property=DropInPaths".to_string(),
        "--property=UnitFileState".to_string(),
        "--property=ActiveState".to_string(),
        "--property=MainPID".to_string(),
        "--property=ControlGroup".to_string(),
        "--property=KillMode".to_string(),
        "--property=ExecStart".to_string(),
        "--property=ExecStartPre".to_string(),
        "--property=ExecStartPost".to_string(),
        "--property=ExecCondition".to_string(),
        "--property=ExecReload".to_string(),
        "--property=ExecStop".to_string(),
        "--property=ExecStopPost".to_string(),
        "--".to_string(),
        service.to_string(),
    ])?;
    if output.exit_code != 0 {
        return Err(CliErrorKind::workflow_io(format!(
            "inspect {service} {phase}: {}",
            output.stderr.trim()
        ))
        .into());
    }
    let id = required_systemd_property(&output.stdout, "Id")?;
    let names = shell_words::split(required_systemd_property(&output.stdout, "Names")?).map_err(
        |error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "parse effective systemd Names: {error}"
            )))
        },
    )?;
    let need_reload = required_systemd_property(&output.stdout, "NeedDaemonReload")?;
    if id != service || !names.iter().map(String::as_str).eq([service]) || need_reload != "no" {
        return Err(CliErrorKind::workflow_io(format!(
            "refusing systemd uninstall with unsafe {phase} identity (Id={id}, Names={names:?}, NeedDaemonReload={need_reload})"
        ))
        .into());
    }
    let load_state = required_systemd_property(&output.stdout, "LoadState")?.to_string();
    let fragment_path = required_systemd_property(&output.stdout, "FragmentPath")?.to_string();
    let drop_in_paths = required_systemd_property(&output.stdout, "DropInPaths")?.to_string();
    let unit_file_state = required_systemd_property(&output.stdout, "UnitFileState")?.to_string();
    let active_state = required_systemd_property(&output.stdout, "ActiveState")?.to_string();
    let main_pid = required_systemd_property(&output.stdout, "MainPID")?
        .parse::<u32>()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "systemctl show returned invalid MainPID {phase}: {error}"
            )))
        })?;
    let control_group = required_systemd_property(&output.stdout, "ControlGroup")?.to_string();
    if !matches!(load_state.as_str(), "loaded" | "masked" | "not-found") || active_state.is_empty()
    {
        return Err(CliErrorKind::workflow_io(format!(
            "refusing systemd uninstall with unsafe {phase} state (LoadState={load_state}, ActiveState={active_state})"
        ))
        .into());
    }
    Ok(UninstallObservation {
        load_state,
        fragment_path,
        drop_in_paths,
        unit_file_state,
        active_state,
        main_pid,
        control_group,
        effective_properties: output.stdout,
    })
}

pub(super) fn require_effective_managed_unit(
    service: &str,
    unit_path: &Path,
    observation: &UninstallObservation,
    phase: &str,
) -> Result<(), CliError> {
    if observation.load_state == "loaded"
        && Path::new(&observation.fragment_path) == unit_path
        && observation.drop_in_paths.is_empty()
    {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(format!(
            "refusing to alter {service} with unexpected effective sources {phase} (LoadState={}, FragmentPath={}, DropInPaths={})",
            observation.load_state, observation.fragment_path, observation.drop_in_paths
        ))
        .into())
    }
}

pub(super) fn require_inhibited_managed_unit(
    service: &str,
    unit_path: &Path,
    inhibitor_path: &Path,
    observation: &UninstallObservation,
    disabled: bool,
) -> Result<(), CliError> {
    let expected_unit_file_state = if disabled {
        observation.unit_file_state == "disabled"
    } else {
        matches!(
            observation.unit_file_state.as_str(),
            "enabled" | "disabled" | "enabled-runtime" | "linked" | "linked-runtime"
        )
    };
    if observation.load_state == "loaded"
        && Path::new(&observation.fragment_path) == unit_path
        && drop_in_paths_are_exact(&observation.drop_in_paths, inhibitor_path)?
        && expected_unit_file_state
    {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(format!(
            "refusing to alter inhibited {service} with unexpected effective sources (LoadState={}, FragmentPath={}, DropInPaths={}, UnitFileState={})",
            observation.load_state,
            observation.fragment_path,
            observation.drop_in_paths,
            observation.unit_file_state
        ))
        .into())
    }
}

fn drop_in_paths_are_exact(value: &str, expected: &Path) -> Result<bool, CliError> {
    let paths = shell_words::split(value).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "parse effective systemd DropInPaths: {error}"
        )))
    })?;
    let expected = expected.to_str().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "systemd inhibitor path is not UTF-8: {}",
            expected.display()
        )))
    })?;
    Ok(paths == [expected])
}

pub(super) fn observation_has_exact_inhibitor(
    observation: &UninstallObservation,
    inhibitor_path: &Path,
) -> Result<bool, CliError> {
    drop_in_paths_are_exact(&observation.drop_in_paths, inhibitor_path)
}

pub(super) fn validate_observed_control_group(
    service: &str,
    observation: &UninstallObservation,
    cgroup_root: &Path,
) -> Result<Option<ValidatedControlGroup>, CliError> {
    let may_be_running = observation.active_state != "inactive" || observation.main_pid > 0;
    if observation.control_group.is_empty() {
        return if may_be_running {
            Err(CliErrorKind::workflow_io(format!(
                "{service} may be running without an effective systemd ControlGroup"
            ))
            .into())
        } else {
            Ok(None)
        };
    }
    let events_file = cgroup_events_file_at(cgroup_root, &observation.control_group)?;
    let validated = validate_control_group_before_stop(events_file)?;
    if may_be_running && !validated.was_populated() {
        return Err(CliErrorKind::workflow_io(format!(
            "{service} may be running but its recursive systemd cgroup is unpopulated"
        ))
        .into());
    }
    Ok(Some(validated))
}

pub(super) fn disable_service<RunSystemctl>(
    service: &str,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    run_disable(
        &[
            "disable".to_string(),
            "--now".to_string(),
            "--".to_string(),
            service.to_string(),
        ],
        run_systemctl,
    )?;
    run_disable(
        &[
            "disable".to_string(),
            "--runtime".to_string(),
            "--".to_string(),
            service.to_string(),
        ],
        run_systemctl,
    )
}

fn run_disable<RunSystemctl>(args: &[String], run_systemctl: &RunSystemctl) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = run_systemctl(args)?;
    if output.exit_code == 0 {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(format!(
            "systemctl {} failed with exit code {}: {}",
            shell_words::join(args.iter().map(String::as_str)),
            output.exit_code,
            output.stderr.trim()
        ))
        .into())
    }
}

pub(super) fn require_no_persistent_enablement(
    unit_path: &Path,
    service: &str,
) -> Result<(), CliError> {
    let unit_directory = unit_path.parent().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "systemd unit path has no parent: {}",
            unit_path.display()
        )))
    })?;
    for entry in fs::read_dir(unit_directory).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "inspect systemd unit directory {}: {error}",
            unit_directory.display()
        )))
    })? {
        let entry = entry.map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "inspect systemd unit directory entry: {error}"
            )))
        })?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "inspect systemd unit entry {}: {error}",
                path.display()
            )))
        })?;
        if metadata.file_type().is_symlink() {
            reject_persistent_link(&path, unit_path, service)?;
        } else if metadata.is_dir() {
            reject_nested_persistent_links(&path, unit_path, service)?;
        }
    }
    Ok(())
}

fn reject_nested_persistent_links(
    directory: &Path,
    unit_path: &Path,
    service: &str,
) -> Result<(), CliError> {
    for entry in fs::read_dir(directory).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "inspect systemd enablement directory {}: {error}",
            directory.display()
        )))
    })? {
        let path = entry
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "inspect systemd enablement entry: {error}"
                )))
            })?
            .path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "inspect systemd enablement entry {}: {error}",
                path.display()
            )))
        })?;
        if metadata.file_type().is_symlink() {
            reject_persistent_link(&path, unit_path, service)?;
        }
    }
    Ok(())
}

fn reject_persistent_link(path: &Path, unit_path: &Path, service: &str) -> Result<(), CliError> {
    let target = fs::read_link(path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "read systemd enablement link {}: {error}",
            path.display()
        )))
    })?;
    let names_service = path.file_name().is_some_and(|name| name == service);
    let targets_service = if target.is_absolute() {
        target == unit_path
    } else {
        target
            .file_name()
            .is_some_and(|name| unit_path.file_name() == Some(name))
    };
    if names_service || targets_service {
        Err(CliErrorKind::workflow_io(format!(
            "systemd unit {service} remains persistently enabled by {} -> {}",
            path.display(),
            target.display()
        ))
        .into())
    } else {
        Ok(())
    }
}

pub(super) fn require_absent_service(
    service: &str,
    observation: &UninstallObservation,
) -> Result<(), CliError> {
    if observation.load_state == "not-found"
        && observation.fragment_path.is_empty()
        && observation.drop_in_paths.is_empty()
        && observation.unit_file_state.is_empty()
        && observation.active_state == "inactive"
        && observation.main_pid == 0
        && observation.control_group.is_empty()
    {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(format!(
            "refusing to alter untracked {service} without its managed files"
        ))
        .into())
    }
}

pub(super) fn observation_is_absent(observation: &UninstallObservation) -> bool {
    observation.load_state == "not-found"
        && observation.fragment_path.is_empty()
        && observation.drop_in_paths.is_empty()
        && observation.unit_file_state.is_empty()
        && observation.active_state == "inactive"
        && observation.main_pid == 0
        && observation.control_group.is_empty()
}

pub(super) fn sync_systemd_unit_filesystem(unit_path: &Path) -> Result<(), CliError> {
    let parent = unit_path.parent().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "systemd unit path has no parent: {}",
            unit_path.display()
        )))
    })?;
    let directory = File::open(parent).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "open systemd unit filesystem {}: {error}",
            parent.display()
        )))
    })?;
    #[cfg(all(target_os = "linux", not(test)))]
    {
        syncfs(&directory).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "sync systemd unit filesystem {}: {error}",
                parent.display()
            )))
        })
    }
    #[cfg(any(not(target_os = "linux"), test))]
    {
        directory.sync_all().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "sync systemd unit directory {}: {error}",
                parent.display()
            )))
        })
    }
}

pub(super) fn remove_managed_file(path: &Path) -> Result<bool, CliError> {
    let removed = match fs::remove_file(path) {
        Ok(()) => true,
        Err(error) if error.kind() == ErrorKind::NotFound => false,
        Err(error) => {
            return Err(CliErrorKind::workflow_io(format!(
                "remove managed file {}: {error}",
                path.display()
            ))
            .into());
        }
    };
    if removed {
        let parent = path.parent().ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "managed file path has no parent: {}",
                path.display()
            )))
        })?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "sync managed file directory {}: {error}",
                    parent.display()
                )))
            })?;
    }
    Ok(removed)
}

pub(super) fn require_stopped_service(
    service: &str,
    before: &UninstallObservation,
    after: &UninstallObservation,
) -> Result<(), CliError> {
    let control_group_unchanged = after.control_group.is_empty()
        || (!before.control_group.is_empty() && after.control_group == before.control_group);
    if after.active_state == "inactive" && after.main_pid == 0 && control_group_unchanged {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(format!(
            "refusing to remove {service} while it may still be running (LoadState={}, ActiveState={}, MainPID={}, ControlGroup={:?})",
            after.load_state, after.active_state, after.main_pid, after.control_group
        ))
        .into())
    }
}
