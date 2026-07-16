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

    let error =
        validate_recovery_unit_sources(&plan, &run).expect_err("recovery drop-in must fail closed");

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

    let error =
        validate_recovery_unit_files(&plan).expect_err("symlink recovery timer must fail closed");

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
