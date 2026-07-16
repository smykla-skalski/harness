use std::path::Path;

use crate::errors::CliError;

use super::super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::super::files::io_error;
use super::super::model::RemoteSystemdOperationPlan;
use super::effective::{
    require_effective_environment, require_effective_exec_contract, require_effective_storage,
};
use super::identity::require_effective_identity;
use super::mount_namespace::{ALTERNATE_MOUNT_PROPERTIES, reject_effective_remaps};
use super::required_property;
use super::runtime::{ServiceType, validate_effective_runtime_contract};

pub(super) fn validate_effective_unit_sources<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    source_type: ServiceType,
    expected_drop_in: Option<&Path>,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let mut arguments = vec![
        "show".to_string(),
        "--property=FragmentPath".to_string(),
        "--property=DropInPaths".to_string(),
        "--property=User".to_string(),
        "--property=Group".to_string(),
        "--property=DynamicUser".to_string(),
        "--property=UID".to_string(),
        "--property=GID".to_string(),
        "--property=MainPID".to_string(),
        "--property=NeedDaemonReload".to_string(),
        "--property=StateDirectory".to_string(),
        "--property=StateDirectoryMode".to_string(),
        "--property=Type".to_string(),
        "--property=NotifyAccess".to_string(),
        "--property=TimeoutStartUSec".to_string(),
        "--property=KillMode".to_string(),
        "--property=Environment".to_string(),
        "--property=EnvironmentFiles".to_string(),
        "--property=ExecStart".to_string(),
        "--property=ExecStartPre".to_string(),
        "--property=ExecStartPost".to_string(),
        "--property=ExecCondition".to_string(),
        "--property=ExecReload".to_string(),
        "--property=ExecStop".to_string(),
        "--property=ExecStopPost".to_string(),
        "--property=UnsetEnvironment".to_string(),
    ];
    let mount_properties =
        ALTERNATE_MOUNT_PROPERTIES.map(|property| format!("--property={property}"));
    arguments.extend(mount_properties);
    arguments.push(plan.service());
    let output = run_systemctl(&arguments)?;
    if output.exit_code != 0 {
        return Err(io_error(format!(
            "inspect effective systemd unit sources for {}: {}",
            plan.service(),
            output.stderr.trim()
        )));
    }
    let fragment = required_property(&output.stdout, "FragmentPath")?;
    let drop_ins = required_property(&output.stdout, "DropInPaths")?;
    if Path::new(fragment) != plan.unit_path {
        return Err(io_error(format!(
            "effective systemd FragmentPath must be {}, found {fragment}",
            plan.unit_path.display()
        )));
    }
    require_expected_drop_in(drop_ins, expected_drop_in)?;
    reject_effective_remaps(&output.stdout)?;
    validate_effective_runtime_contract(&output.stdout, source_type)?;
    require_effective_identity(&output.stdout)?;
    require_effective_storage(&output.stdout, plan)?;
    require_effective_environment(&output.stdout, plan)?;
    require_effective_exec_contract(&output.stdout, &plan.binary_path)
}

fn require_expected_drop_in(
    drop_ins: &str,
    expected_drop_in: Option<&Path>,
) -> Result<(), CliError> {
    let observed = shell_words::split(drop_ins)
        .map_err(|error| io_error(format!("parse effective systemd DropInPaths: {error}")))?;
    let expected = expected_drop_in
        .map(|path| {
            path.to_str().ok_or_else(|| {
                io_error(format!(
                    "systemd inhibitor path is not UTF-8: {}",
                    path.display()
                ))
            })
        })
        .transpose()?;
    if observed.iter().map(String::as_str).eq(expected) {
        Ok(())
    } else {
        Err(io_error(format!(
            "managed systemd unit has unexpected drop-ins: {observed:?}"
        )))
    }
}
