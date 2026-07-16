use std::path::Path;

use crate::errors::CliError;

use super::super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::super::files::{
    existing_contents, io_error, remove_file_if_exists, validate_bytes_absent_or_exact,
    write_bytes_atomic_if_absent_or_exact,
};
use super::super::model::{
    FileMetadata, RECOVERY_ARM_FILE, RECOVERY_CONTROLLER_FILE, RemoteSystemdOperationPlan,
};

const RECOVERY_DEFER_EXIT_STATUS: i32 = 75;

pub(super) fn validate_recovery_unit_files(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    validate_recovery_unit_files_at(&plan.unit, &plan.unit_path, &plan.store_path)
}

pub(in super::super) fn validate_recovery_unit_files_at(
    unit: &str,
    unit_path: &Path,
    store_path: &Path,
) -> Result<(), CliError> {
    let (service, timer) = render_recovery_units_at(unit, store_path);
    let service_path = unit_path.with_file_name(format!("{unit}-harness-recovery.service"));
    let timer_path = unit_path.with_file_name(format!("{unit}-harness-recovery.timer"));
    validate_bytes_absent_or_exact(&service_path, service.as_bytes())?;
    validate_bytes_absent_or_exact(&timer_path, timer.as_bytes())
}

pub(super) fn write_recovery_units(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    let metadata = FileMetadata::private_executable().with_mode(0o644);
    let (service, timer) = render_recovery_units(plan);
    write_bytes_atomic_if_absent_or_exact(
        &plan.recovery_service_path(),
        service.as_bytes(),
        metadata,
    )?;
    write_bytes_atomic_if_absent_or_exact(&plan.recovery_timer_path(), timer.as_bytes(), metadata)
}

pub(super) fn remove_recovery_unit_files_if_managed(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    remove_recovery_unit_files_at(&plan.unit, &plan.unit_path, &plan.store_path)
}

pub(in super::super) fn remove_recovery_unit_files_at(
    unit: &str,
    unit_path: &Path,
    store_path: &Path,
) -> Result<(), CliError> {
    let (service, timer) = render_recovery_units_at(unit, store_path);
    let service_path = unit_path.with_file_name(format!("{unit}-harness-recovery.service"));
    let timer_path = unit_path.with_file_name(format!("{unit}-harness-recovery.timer"));
    remove_if_managed(&timer_path, timer.as_bytes())?;
    remove_if_managed(&service_path, service.as_bytes())
}

fn remove_if_managed(path: &Path, expected: &[u8]) -> Result<(), CliError> {
    match existing_contents(path)? {
        Some(contents) if contents == expected => remove_file_if_exists(path),
        Some(_) => Err(io_error(format!(
            "refusing to remove unrelated existing recovery unit {}",
            path.display()
        ))),
        None => Ok(()),
    }
}

pub(super) fn validate_recovery_unit_sources<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    for (name, path) in [
        (plan.recovery_service_name(), plan.recovery_service_path()),
        (plan.recovery_timer_name(), plan.recovery_timer_path()),
    ] {
        validate_effective_source(&name, &path, run_systemctl)?;
    }
    Ok(())
}

pub(super) fn validate_recovery_timer_active<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let timer = plan.recovery_timer_name();
    let output = run_systemctl(&[
        "show".to_string(),
        "--property=LoadState".to_string(),
        "--property=FragmentPath".to_string(),
        "--property=DropInPaths".to_string(),
        "--property=ActiveState".to_string(),
        "--property=UnitFileState".to_string(),
        "--".to_string(),
        timer.clone(),
    ])?;
    require_successful_show(&timer, &output)?;
    validate_source_properties(&timer, &plan.recovery_timer_path(), &output.stdout)?;
    require_property(&output.stdout, "ActiveState", "active")?;
    require_property(&output.stdout, "UnitFileState", "enabled")
}

fn validate_effective_source<RunSystemctl>(
    name: &str,
    path: &Path,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = run_systemctl(&[
        "show".to_string(),
        "--property=LoadState".to_string(),
        "--property=FragmentPath".to_string(),
        "--property=DropInPaths".to_string(),
        "--".to_string(),
        name.to_string(),
    ])?;
    require_successful_show(name, &output)?;
    validate_source_properties(name, path, &output.stdout)
}

fn require_successful_show(
    name: &str,
    output: &RemoteSystemdCommandOutput,
) -> Result<(), CliError> {
    if output.exit_code == 0 {
        Ok(())
    } else {
        Err(io_error(format!(
            "inspect effective recovery unit {name}: {}",
            output.stderr.trim()
        )))
    }
}

fn validate_source_properties(name: &str, path: &Path, stdout: &str) -> Result<(), CliError> {
    require_property(stdout, "LoadState", "loaded")?;
    let fragment = required_property(stdout, "FragmentPath")?;
    if Path::new(fragment) != path {
        return Err(io_error(format!(
            "effective recovery unit {name} must load {}, found {fragment}",
            path.display()
        )));
    }
    require_property(stdout, "DropInPaths", "")
}

fn require_property(stdout: &str, name: &str, expected: &str) -> Result<(), CliError> {
    let observed = required_property(stdout, name)?;
    if observed == expected {
        Ok(())
    } else {
        Err(io_error(format!(
            "effective recovery unit requires {name}={expected}, found {observed}"
        )))
    }
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

pub(super) fn render_recovery_units(plan: &RemoteSystemdOperationPlan) -> (String, String) {
    render_recovery_units_at(&plan.unit, &plan.store_path)
}

fn render_recovery_units_at(unit: &str, store_path: &Path) -> (String, String) {
    (
        render_recovery_service(unit, store_path),
        render_recovery_timer(unit),
    )
}

fn render_recovery_service(unit: &str, store_path: &Path) -> String {
    let controller = render_systemd_argument(&store_path.join(RECOVERY_CONTROLLER_FILE));
    let store = render_systemd_argument(store_path);
    format!(
        "[Unit]\n\
         Description=Recover interrupted Harness transaction for {}\n\
         After=local-fs.target\n\
         ConditionPathExists={}\n\
         \n\
         [Service]\n\
         Type=oneshot\n\
         ExecStart={controller} remote recover-systemd --store-path {store} --json\n\
         SuccessExitStatus={RECOVERY_DEFER_EXIT_STATUS}\n\
         TimeoutStartSec=infinity\n\
         NoNewPrivileges=true\n\
         PrivateTmp=true\n\
         ProtectHome=true\n\
         UMask=0077\n",
        unit,
        store_path.join(RECOVERY_ARM_FILE).display()
    )
}

fn render_recovery_timer(unit: &str) -> String {
    let service = format!("{unit}-harness-recovery.service");
    format!(
        "[Unit]\n\
         Description=Watch interrupted Harness transaction for {unit}\n\
         \n\
         [Timer]\n\
         OnBootSec=1s\n\
         OnUnitInactiveSec=5s\n\
         AccuracySec=1s\n\
         Unit={service}\n\
         \n\
         [Install]\n\
         WantedBy=timers.target\n"
    )
}

fn render_systemd_argument(path: &Path) -> String {
    let value = path.as_os_str().to_string_lossy();
    let escaped = value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%");
    format!("\"{escaped}\"")
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _, symlink};
    use std::time::Duration;

    use tempfile::tempdir;

    use super::super::super::model::RecoveryOperation;
    use super::*;

    #[test]
    fn recovery_units_require_exact_sources_and_active_enabled_timer() {
        let temp = tempdir().expect("temporary directory");
        let plan = test_plan(temp.path());
        let run = |args: &[String]| {
            let name = args.last().expect("systemd unit name");
            let path = if name == &plan.recovery_service_name() {
                plan.recovery_service_path()
            } else {
                plan.recovery_timer_path()
            };
            Ok(output(format!(
                "LoadState=loaded\nFragmentPath={}\nDropInPaths=\nActiveState=active\nUnitFileState=enabled\n",
                path.display()
            )))
        };

        validate_recovery_unit_sources(&plan, &run).expect("trusted recovery unit sources");
        validate_recovery_timer_active(&plan, &run).expect("active recovery timer");
    }

    #[test]
    fn recovery_unit_drop_ins_fail_before_arming() {
        let temp = tempdir().expect("temporary directory");
        let plan = test_plan(temp.path());
        let run = |args: &[String]| {
            let name = args.last().expect("systemd unit name");
            let path = if name == &plan.recovery_service_name() {
                plan.recovery_service_path()
            } else {
                plan.recovery_timer_path()
            };
            Ok(output(format!(
                "LoadState=loaded\nFragmentPath={}\nDropInPaths=/run/systemd/system/override.conf\n",
                path.display()
            )))
        };

        let error = validate_recovery_unit_sources(&plan, &run)
            .expect_err("recovery drop-in must fail closed");

        assert!(error.to_string().contains("DropInPaths"));
    }

    #[test]
    fn recovery_unit_writes_refuse_unrelated_existing_files_before_mutation() {
        let temp = tempdir().expect("temporary directory");
        let plan = test_plan(temp.path());
        let service_path = plan.recovery_service_path();
        fs::write(&plan.binary_path, "controller\n").expect("controller source");
        fs::write(&service_path, "unrelated service\n").expect("unrelated service");
        fs::set_permissions(&service_path, fs::Permissions::from_mode(0o644))
            .expect("trusted service permissions");
        let run = |_args: &[String]| Ok(output("enabled\n".to_string()));

        let error = super::super::arm_recovery_automation(
            &plan,
            &plan.binary_path,
            "transaction",
            RecoveryOperation::Upgrade,
            "before",
            "target",
            &run,
        )
        .expect_err("unrelated recovery service must fail closed");

        assert!(error.to_string().contains("refusing to replace unrelated"));
        assert_eq!(
            fs::read_to_string(service_path).expect("unchanged unrelated service"),
            "unrelated service\n"
        );
        assert!(!plan.recovery_timer_path().exists());
        assert!(!plan.recovery_controller_path().exists());
    }

    #[test]
    fn recovery_unit_writes_refuse_symlinks_before_mutation() {
        let temp = tempdir().expect("temporary directory");
        let plan = test_plan(temp.path());
        let target = temp.path().join("unrelated");
        fs::write(&target, "unrelated\n").expect("symlink target");
        symlink(&target, plan.recovery_timer_path()).expect("recovery timer symlink");

        let error = validate_recovery_unit_files(&plan)
            .expect_err("symlink recovery timer must fail closed");

        assert!(error.to_string().contains("refusing to replace unrelated"));
        assert_eq!(
            fs::read_to_string(target).expect("unchanged symlink target"),
            "unrelated\n"
        );
        assert!(!plan.recovery_service_path().exists());
    }

    #[test]
    fn recovery_unit_writes_refuse_nonregular_files_before_mutation() {
        let temp = tempdir().expect("temporary directory");
        let plan = test_plan(temp.path());
        fs::create_dir(plan.recovery_service_path()).expect("recovery service directory");

        let error = validate_recovery_unit_files(&plan)
            .expect_err("nonregular recovery service must fail closed");

        assert!(error.to_string().contains("refusing to replace unrelated"));
        assert!(plan.recovery_service_path().is_dir());
        assert!(!plan.recovery_timer_path().exists());
    }

    #[test]
    fn exact_recovery_units_are_accepted_idempotently() {
        let temp = tempdir().expect("temporary directory");
        let plan = test_plan(temp.path());
        let (service, timer) = render_recovery_units(&plan);
        fs::write(plan.recovery_service_path(), &service).expect("managed service");
        fs::write(plan.recovery_timer_path(), &timer).expect("managed timer");
        fs::set_permissions(
            plan.recovery_service_path(),
            fs::Permissions::from_mode(0o644),
        )
        .expect("managed service permissions");
        fs::set_permissions(
            plan.recovery_timer_path(),
            fs::Permissions::from_mode(0o644),
        )
        .expect("managed timer permissions");
        let service_inode = fs::metadata(plan.recovery_service_path())
            .expect("managed service metadata")
            .ino();
        let timer_inode = fs::metadata(plan.recovery_timer_path())
            .expect("managed timer metadata")
            .ino();

        validate_recovery_unit_files(&plan).expect("exact units pass preflight");
        write_recovery_units(&plan).expect("exact units pass write");

        assert_eq!(
            fs::read_to_string(plan.recovery_service_path()).expect("managed service"),
            service
        );
        assert_eq!(
            fs::read_to_string(plan.recovery_timer_path()).expect("managed timer"),
            timer
        );
        assert_eq!(
            fs::metadata(plan.recovery_service_path())
                .expect("managed service metadata")
                .ino(),
            service_inode
        );
        assert_eq!(
            fs::metadata(plan.recovery_timer_path())
                .expect("managed timer metadata")
                .ino(),
            timer_inode
        );
    }

    fn test_plan(root: &Path) -> RemoteSystemdOperationPlan {
        RemoteSystemdOperationPlan {
            unit: "harness-remote".to_string(),
            binary_path: root.join("harness"),
            unit_path: root.join("harness-remote.service"),
            environment_path: root.join("harness-remote.env"),
            state_path: root.join("state").join("harness"),
            store_path: root.join("transactions").join("harness-remote"),
            controller_path: root.join("harness"),
            readiness_timeout: Duration::from_secs(1),
            stabilization_window: Duration::ZERO,
        }
    }

    fn output(stdout: String) -> RemoteSystemdCommandOutput {
        RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout,
            stderr: String::new(),
        }
    }
}
