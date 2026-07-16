use std::path::{Path, PathBuf};

use crate::daemon::transport::remote_systemd_cgroup::require_unpopulated_control_group;
use crate::daemon::transport::remote_systemd_inhibitor::{
    inhibitor_is_installed, inhibitor_path, install_inhibitor, remove_inhibitor,
};
use crate::daemon::transport::remote_systemd_start_permit::{
    remove_stale_runtime_start_permit, require_runtime_start_permit_absent,
};
use crate::errors::{CliError, CliErrorKind};

use super::install_files::read_trusted_managed_file;
use super::{
    RemoteSystemdCommandOutput, RemoteSystemdUninstallReport, run_checked, unit_service_name,
    validate_canonical_unit_name,
};

const SYSTEM_CGROUP_ROOT: &str = "/sys/fs/cgroup";

#[path = "uninstall/effective.rs"]
mod effective;
#[path = "uninstall/systemd.rs"]
mod systemd;

use systemd::{
    disable_service, observe_uninstall_service, remove_managed_file, require_absent_service,
    require_effective_managed_unit, require_inhibited_managed_unit,
    require_no_persistent_enablement, require_stopped_service, sync_systemd_unit_filesystem,
    validate_observed_control_group,
};

#[derive(Debug)]
struct UninstallFiles {
    managed_binary_path: Option<PathBuf>,
    inhibitor_present: bool,
}

#[derive(Debug)]
struct UninstallObservation {
    load_state: String,
    fragment_path: String,
    drop_in_paths: String,
    unit_file_state: String,
    active_state: String,
    main_pid: u32,
    control_group: String,
    effective_properties: String,
}

pub(crate) fn preflight_uninstall_managed_binary(
    unit_path: &Path,
    env_path: &Path,
) -> Result<Option<PathBuf>, CliError> {
    validate_uninstall_file_contract(unit_path, env_path).map(|files| files.managed_binary_path)
}

pub(crate) fn uninstall_remote_systemd_with<RunSystemctl>(
    unit: &str,
    unit_path: &Path,
    env_path: &Path,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdUninstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    uninstall_remote_systemd_with_root(
        unit,
        unit_path,
        env_path,
        Path::new(SYSTEM_CGROUP_ROOT),
        run_systemctl,
    )
}

#[cfg(test)]
pub(crate) fn uninstall_remote_systemd_with_cgroup_root<RunSystemctl>(
    unit: &str,
    unit_path: &Path,
    env_path: &Path,
    cgroup_root: &Path,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdUninstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    uninstall_remote_systemd_with_root(unit, unit_path, env_path, cgroup_root, run_systemctl)
}

fn uninstall_remote_systemd_with_root<RunSystemctl>(
    unit: &str,
    unit_path: &Path,
    env_path: &Path,
    cgroup_root: &Path,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdUninstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    validate_canonical_unit_name(unit)?;
    let files = validate_uninstall_file_contract(unit_path, env_path)?;
    let service = unit_service_name(unit);
    if remove_stale_runtime_start_permit(unit_path)? {
        run_checked(run_systemctl, &["daemon-reload".to_string()])?;
    }
    let before = observe_uninstall_service(&service, "before inhibition", run_systemctl)?;
    let Some(binary_path) = files.managed_binary_path else {
        return resume_or_report_absent(
            unit,
            unit_path,
            env_path,
            &service,
            files.inhibitor_present,
            &before,
            run_systemctl,
        );
    };
    let inhibitor = inhibitor_path(unit_path)?;
    if files.inhibitor_present {
        if systemd::observation_has_exact_inhibitor(&before, &inhibitor)? {
            require_inhibited_managed_unit(&service, unit_path, &inhibitor, &before, false)?;
        } else {
            require_effective_managed_unit(
                &service,
                unit_path,
                &before,
                "before inhibitor reload",
            )?;
        }
    } else {
        require_effective_managed_unit(&service, unit_path, &before, "before inhibition")?;
    }
    effective::validate_effective_exec_contract(&before.effective_properties, &binary_path)?;
    install_inhibitor(unit_path)?;
    run_checked(run_systemctl, &["daemon-reload".to_string()])?;
    let inhibited = observe_uninstall_service(&service, "after inhibition", run_systemctl)?;
    require_inhibited_managed_unit(&service, unit_path, &inhibitor, &inhibited, false)?;
    effective::validate_effective_exec_contract(&inhibited.effective_properties, &binary_path)?;
    let control_group = validate_observed_control_group(&service, &inhibited, cgroup_root)?;
    disable_service(&service, run_systemctl)?;
    sync_systemd_unit_filesystem(unit_path)?;
    require_no_persistent_enablement(unit_path, &service)?;
    let after = observe_uninstall_service(&service, "after disable", run_systemctl)?;
    require_inhibited_managed_unit(&service, unit_path, &inhibitor, &after, true)?;
    effective::validate_effective_exec_contract(&after.effective_properties, &binary_path)?;
    require_stopped_service(&service, &inhibited, &after)?;
    require_unpopulated_control_group(control_group.as_ref())?;
    let env_removed = remove_managed_file(env_path)?;
    let unit_removed = remove_managed_file(unit_path)?;
    run_checked(run_systemctl, &["daemon-reload".to_string()])?;
    let inhibited_absent = observe_uninstall_service(&service, "after removal", run_systemctl)?;
    require_absent_service(&service, &inhibited_absent)?;
    if !inhibitor_is_installed(unit_path)? {
        return Err(CliErrorKind::workflow_io(format!(
            "systemd inhibitor disappeared before absence was proven for {service}"
        ))
        .into());
    }
    release_inhibitor_after_absence(unit_path, &service, run_systemctl)?;
    Ok(RemoteSystemdUninstallReport {
        unit: unit.to_string(),
        unit_path: unit_path.to_path_buf(),
        env_path: env_path.to_path_buf(),
        unit_removed,
        env_removed,
        disabled: true,
        disable_exit_code: Some(0),
        disable_error: None,
        daemon_reloaded: true,
    })
}

fn resume_or_report_absent<RunSystemctl>(
    unit: &str,
    unit_path: &Path,
    env_path: &Path,
    service: &str,
    inhibitor_present: bool,
    before: &UninstallObservation,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdUninstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    if !inhibitor_present && systemd::observation_is_absent(before) {
        return Ok(noop_report(unit, unit_path, env_path));
    }
    if inhibitor_present {
        run_checked(run_systemctl, &["daemon-reload".to_string()])?;
        let observation = observe_uninstall_service(
            service,
            "resume after managed source removal",
            run_systemctl,
        )?;
        require_absent_service(service, &observation)?;
        release_inhibitor_after_absence(unit_path, service, run_systemctl)?;
    } else {
        return Err(CliErrorKind::workflow_io(format!(
            "refusing to alter untracked {service} without its managed files or inhibitor"
        ))
        .into());
    }
    Ok(RemoteSystemdUninstallReport {
        unit: unit.to_string(),
        unit_path: unit_path.to_path_buf(),
        env_path: env_path.to_path_buf(),
        unit_removed: false,
        env_removed: false,
        disabled: true,
        disable_exit_code: Some(0),
        disable_error: None,
        daemon_reloaded: true,
    })
}

fn release_inhibitor_after_absence<RunSystemctl>(
    unit_path: &Path,
    service: &str,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    require_runtime_start_permit_absent(unit_path)?;
    let release = remove_inhibitor(unit_path)
        .and_then(|_| run_checked(run_systemctl, &["daemon-reload".to_string()]))
        .and_then(|()| observe_uninstall_service(service, "after inhibitor removal", run_systemctl))
        .and_then(|observation| require_absent_service(service, &observation));
    if let Err(error) = release {
        let recovery = restore_absence_inhibitor(unit_path, service, run_systemctl);
        return Err(match recovery {
            Ok(()) => error,
            Err(recovery_error) => CliErrorKind::workflow_io(format!(
                "release systemd uninstall inhibitor failed: {error}; restoring the inhibitor also failed: {recovery_error}"
            ))
            .into(),
        });
    }
    Ok(())
}

fn restore_absence_inhibitor<RunSystemctl>(
    unit_path: &Path,
    service: &str,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let inhibitor = install_inhibitor(unit_path)?;
    run_checked(run_systemctl, &["daemon-reload".to_string()])?;
    let observation = observe_uninstall_service(
        service,
        "after failed inhibitor release recovery",
        run_systemctl,
    )?;
    if systemd::observation_is_absent(&observation)
        || (systemd::observation_has_exact_inhibitor(&observation, &inhibitor)?
            && observation.active_state == "inactive"
            && observation.main_pid == 0)
    {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(format!(
            "could not prove {service} is quiescent under its restored uninstall inhibitor"
        ))
        .into())
    }
}

fn validate_uninstall_file_contract(
    unit_path: &Path,
    env_path: &Path,
) -> Result<UninstallFiles, CliError> {
    let inhibitor_present = inhibitor_is_installed(unit_path)?;
    let unit = read_trusted_managed_file(unit_path, "systemd unit")?;
    let environment = read_trusted_managed_file(env_path, "systemd environment")?;
    let Some(unit) = unit else {
        return if environment.is_none() {
            Ok(UninstallFiles {
                managed_binary_path: None,
                inhibitor_present,
            })
        } else {
            Err(CliErrorKind::workflow_io(format!(
                "refusing to remove unreferenced systemd environment {} without its managed unit",
                env_path.display()
            ))
            .into())
        };
    };
    let expected = env_path.to_str().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "systemd environment path is not UTF-8: {}",
            env_path.display()
        )))
    })?;
    let observed = service_directive_values(&unit, "EnvironmentFile");
    if observed != [expected] {
        return Err(CliErrorKind::workflow_io(format!(
            "refusing to remove systemd environment {}; managed unit references {observed:?}",
            env_path.display()
        ))
        .into());
    }
    let managed_binary_path = effective::validate_source_contract(&unit)?;
    Ok(UninstallFiles {
        managed_binary_path: Some(managed_binary_path),
        inhibitor_present,
    })
}

fn service_directive_values<'a>(contents: &'a str, name: &str) -> Vec<&'a str> {
    let mut in_service = false;
    contents
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.starts_with('[') && line.ends_with(']') {
                in_service = line == "[Service]";
                return None;
            }
            if !in_service || line.starts_with('#') || line.starts_with(';') {
                return None;
            }
            line.split_once('=')
                .filter(|(key, _)| key.trim() == name)
                .map(|(_, value)| value.trim())
        })
        .collect()
}

fn noop_report(unit: &str, unit_path: &Path, env_path: &Path) -> RemoteSystemdUninstallReport {
    RemoteSystemdUninstallReport {
        unit: unit.to_string(),
        unit_path: unit_path.to_path_buf(),
        env_path: env_path.to_path_buf(),
        unit_removed: false,
        env_removed: false,
        disabled: false,
        disable_exit_code: None,
        disable_error: None,
        daemon_reloaded: false,
    }
}
