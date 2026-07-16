use std::cell::{Cell, RefCell};
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
use std::time::Duration;

use tempfile::{TempDir, tempdir};

use super::super::automation::render_recovery_units_for_tests;
use super::super::files::create_private_directory;
use super::super::model::{RECOVERY_CONTROLLER_FILE, RemoteSystemdOperationPlan};
use super::*;

const UNIT: &str = "harness-remote";

#[test]
fn cleanup_disables_proven_timer_and_proves_units_absent() {
    let fixture = CleanupFixture::with_artifacts();
    let timer_disabled = Cell::new(false);
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        if command(args) == Some("disable") {
            timer_disabled.set(true);
        }
        Ok(scripted_output(&fixture, args, timer_disabled.get()))
    };

    cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect("cleanup recovery artifacts");

    fixture.assert_artifacts_absent();
    assert_eq!(count_command(&calls.borrow(), "disable"), 1);
    assert_eq!(count_command(&calls.borrow(), "daemon-reload"), 1);
}

#[test]
fn cleanup_continues_when_one_requested_recovery_unit_is_unloaded() {
    let fixture = CleanupFixture::with_artifacts();
    let timer_disabled = Cell::new(false);
    let runner = |args: &[String]| {
        if command(args) == Some("disable") {
            timer_disabled.set(true);
        }
        if command(args) == Some("reset-failed") {
            return Ok(command_output(
                1,
                "",
                "Failed to reset failed state of unit harness-remote-harness-recovery.service: Unit harness-remote-harness-recovery.service not loaded.\n",
            ));
        }
        Ok(scripted_output(&fixture, args, timer_disabled.get()))
    };

    cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect("unloaded recovery unit is already clear of failed state");

    fixture.assert_artifacts_absent();
}

#[test]
fn shadowed_recovery_service_fails_before_disable_and_preserves_artifacts() {
    let fixture = CleanupFixture::with_artifacts();
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        if command(args) == Some("show")
            && args.last().is_some_and(|name| name.ends_with(".service"))
        {
            return Ok(show_output(
                "loaded",
                "inactive",
                Some(0),
                Path::new("/usr/lib/systemd/system/untracked.service"),
                "",
                "static",
            ));
        }
        Ok(scripted_output(&fixture, args, false))
    };

    let error = cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect_err("shadowed service must fail closed");

    assert!(error.to_string().contains("unexpected effective sources"));
    assert_eq!(count_command(&calls.borrow(), "disable"), 0);
    fixture.assert_artifacts_present();
}

#[test]
fn recovery_timer_drop_in_fails_before_disable() {
    let fixture = CleanupFixture::with_artifacts();
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        let mut output = scripted_output(&fixture, args, false);
        if command(args) == Some("show") && args.last().is_some_and(|name| name.ends_with(".timer"))
        {
            output.stdout = output.stdout.replace(
                "DropInPaths=\n",
                "DropInPaths=/run/systemd/system/untrusted.conf\n",
            );
        }
        Ok(output)
    };

    cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect_err("recovery timer drop-in must fail closed");

    assert_eq!(count_command(&calls.borrow(), "disable"), 0);
    fixture.assert_artifacts_present();
}

#[test]
fn timer_still_enabled_after_disable_preserves_artifacts() {
    let fixture = CleanupFixture::with_artifacts();
    let disabled = Cell::new(false);
    let runner = |args: &[String]| {
        if command(args) == Some("disable") {
            disabled.set(true);
            return Ok(command_output(0, "", ""));
        }
        if command(args) == Some("show")
            && disabled.get()
            && args.last().is_some_and(|name| name.ends_with(".timer"))
        {
            return Ok(show_output(
                "loaded",
                "inactive",
                None,
                &fixture.plan.recovery_timer_path(),
                "",
                "enabled",
            ));
        }
        Ok(scripted_output(&fixture, args, false))
    };

    let error = cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect_err("enabled timer must block removal");

    assert!(error.to_string().contains("remained enabled"));
    fixture.assert_artifacts_present();
}

#[test]
fn timer_main_pid_property_is_rejected() {
    let fixture = CleanupFixture::with_artifacts();
    let runner = |args: &[String]| {
        if command(args) == Some("show") && args.last().is_some_and(|name| name.ends_with(".timer"))
        {
            return Ok(show_output(
                "loaded",
                "active",
                Some(42),
                &fixture.plan.recovery_timer_path(),
                "",
                "enabled",
            ));
        }
        Ok(scripted_output(&fixture, args, false))
    };

    let error = cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect_err("timer MainPID must fail closed");

    assert!(error.to_string().contains("unexpectedly returned MainPID"));
    fixture.assert_artifacts_present();
}

#[test]
fn symlinked_recovery_unit_is_never_removed() {
    let fixture = CleanupFixture::empty();
    let service_path = fixture.plan.recovery_service_path();
    std::os::unix::fs::symlink("/etc/passwd", &service_path).expect("symlink recovery service");
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("file contract must fail before systemctl")
    };

    cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect_err("symlinked recovery unit must fail closed");

    assert!(
        std::fs::symlink_metadata(&service_path)
            .expect("symlink remains")
            .file_type()
            .is_symlink()
    );
}

#[test]
fn absent_recovery_artifacts_and_units_are_a_read_only_noop() {
    let fixture = CleanupFixture::empty();
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        Ok(scripted_output(&fixture, args, false))
    };

    cleanup_recovery_artifacts(
        UNIT,
        &fixture.plan.unit_path,
        &fixture.plan.store_path,
        &runner,
    )
    .expect("absent recovery cleanup");

    assert_eq!(count_command(&calls.borrow(), "show"), 2);
    assert_eq!(count_mutating_commands(&calls.borrow()), 0);
}

struct CleanupFixture {
    _temp: TempDir,
    plan: RemoteSystemdOperationPlan,
}

impl CleanupFixture {
    fn empty() -> Self {
        let temp = tempdir().expect("temporary directory");
        let unit_directory = temp.path().join("systemd");
        std::fs::create_dir(&unit_directory).expect("systemd directory");
        let store_path = temp.path().join("store");
        create_private_directory(&store_path).expect("private store");
        let plan = RemoteSystemdOperationPlan {
            unit: UNIT.to_string(),
            binary_path: temp.path().join("harness"),
            unit_path: unit_directory.join(format!("{UNIT}.service")),
            environment_path: temp.path().join("harness.env"),
            state_path: temp.path().join("state"),
            store_path,
            controller_path: temp.path().join("harness"),
            readiness_timeout: Duration::from_secs(1),
            stabilization_window: Duration::ZERO,
        };
        Self { _temp: temp, plan }
    }

    fn with_artifacts() -> Self {
        let fixture = Self::empty();
        let (service, timer) = render_recovery_units_for_tests(&fixture.plan);
        std::fs::write(fixture.plan.recovery_service_path(), service).expect("recovery service");
        std::fs::write(fixture.plan.recovery_timer_path(), timer).expect("recovery timer");
        let controller = fixture.plan.store_path.join(RECOVERY_CONTROLLER_FILE);
        std::fs::write(&controller, b"controller").expect("recovery controller");
        std::fs::set_permissions(&controller, std::fs::Permissions::from_mode(0o700))
            .expect("controller permissions");
        fixture
    }

    fn assert_artifacts_present(&self) {
        assert!(self.plan.recovery_service_path().is_file());
        assert!(self.plan.recovery_timer_path().is_file());
        assert!(
            self.plan
                .store_path
                .join(RECOVERY_CONTROLLER_FILE)
                .is_file()
        );
    }

    fn assert_artifacts_absent(&self) {
        assert!(!self.plan.recovery_service_path().exists());
        assert!(!self.plan.recovery_timer_path().exists());
        assert!(!self.plan.store_path.join(RECOVERY_CONTROLLER_FILE).exists());
    }
}

fn scripted_output(
    fixture: &CleanupFixture,
    args: &[String],
    timer_disabled: bool,
) -> RemoteSystemdCommandOutput {
    if command(args) != Some("show") {
        return command_output(0, "", "");
    }
    let name = args.last().expect("recovery unit name");
    let timer = name.ends_with(".timer");
    let path = if timer {
        fixture.plan.recovery_timer_path()
    } else {
        fixture.plan.recovery_service_path()
    };
    if !path.exists() {
        return absent_show_output(timer);
    }
    let active_state = if timer && !timer_disabled {
        "active"
    } else {
        "inactive"
    };
    let unit_file_state = if timer {
        if timer_disabled {
            "disabled"
        } else {
            "enabled"
        }
    } else {
        "static"
    };
    show_output(
        "loaded",
        active_state,
        (!timer).then_some(0),
        &path,
        "",
        unit_file_state,
    )
}

fn absent_show_output(timer: bool) -> RemoteSystemdCommandOutput {
    show_output(
        "not-found",
        "inactive",
        (!timer).then_some(0),
        Path::new(""),
        "",
        "",
    )
}

fn show_output(
    load_state: &str,
    active_state: &str,
    main_pid: Option<u32>,
    fragment_path: &Path,
    drop_in_paths: &str,
    unit_file_state: &str,
) -> RemoteSystemdCommandOutput {
    let main_pid = main_pid.map_or_else(String::new, |pid| format!("MainPID={pid}\n"));
    command_output(
        0,
        &format!(
            "LoadState={load_state}\nActiveState={active_state}\n{main_pid}FragmentPath={}\nDropInPaths={drop_in_paths}\nUnitFileState={unit_file_state}\n",
            fragment_path.display()
        ),
        "",
    )
}

fn command_output(exit_code: i32, stdout: &str, stderr: &str) -> RemoteSystemdCommandOutput {
    RemoteSystemdCommandOutput {
        exit_code,
        stdout: stdout.to_string(),
        stderr: stderr.to_string(),
    }
}

fn command(args: &[String]) -> Option<&str> {
    args.first().map(String::as_str)
}

fn count_command(calls: &[Vec<String>], expected: &str) -> usize {
    calls
        .iter()
        .filter(|args| command(args) == Some(expected))
        .count()
}

fn count_mutating_commands(calls: &[Vec<String>]) -> usize {
    calls
        .iter()
        .filter(|args| command(args).is_some_and(|name| name != "show"))
        .count()
}
