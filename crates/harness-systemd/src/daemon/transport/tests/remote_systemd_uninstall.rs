use std::cell::{Cell, RefCell};
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use tempfile::{TempDir, tempdir_in};

use crate::errors::CliError;

use super::super::remote_systemd_inhibitor::{
    inhibitor_is_installed, inhibitor_path, install_inhibitor,
};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, uninstall_remote_systemd_with,
    uninstall_remote_systemd_with_cgroup_root,
};

const UNIT: &str = "harness-remote-daemon";
const CONTROL_GROUP: &str = "/system.slice/harness-remote-daemon.service";
const BINARY: &str = "/usr/local/bin/harness-daemon";

fn trusted_temp() -> TempDir {
    tempdir_in(env!("CARGO_MANIFEST_DIR")).expect("trusted temp dir")
}

#[path = "remote_systemd_uninstall/retry.rs"]
mod retry;
#[path = "remote_systemd_uninstall/sources.rs"]
mod sources;

#[test]
fn uninstall_preserves_managed_files_when_disable_fails() {
    let fixture = UninstallFixture::new();
    let show_count = Cell::new(0_u8);
    let runner = |args: &[String]| {
        if command(args) == Some("disable") {
            return Ok(command_output(5, "", "unit not loaded"));
        }
        let current = show_count.get();
        show_count.set(current + 1);
        Ok(if current == 0 {
            managed_show_output(&fixture, "inactive", 0, "")
        } else {
            inhibited_managed_show_output(&fixture, "enabled", "inactive", 0, "")
        })
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("disable failure must abort uninstall");

    assert!(error.to_string().contains("exit code 5"));
    fixture.assert_files_present();
}

#[test]
fn uninstall_rejects_wrong_environment_reference_before_systemctl() {
    let fixture = UninstallFixture::new();
    fs::write(
        &fixture.unit_path,
        "[Service]\nEnvironmentFile=/etc/passwd\n",
    )
    .expect("replace managed unit");
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("file contract must fail before systemctl")
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("wrong environment reference must fail closed");

    assert!(error.to_string().contains("managed unit references"));
    fixture.assert_files_present();
}

#[test]
fn uninstall_rejects_source_exec_stop_before_systemctl() {
    let fixture = UninstallFixture::new();
    let contents = fs::read_to_string(&fixture.unit_path).expect("read managed unit");
    fs::write(
        &fixture.unit_path,
        contents.replace(
            "KillMode=control-group\n",
            "KillMode=control-group\nExecStop=/bin/sh -c true\n",
        ),
    )
    .expect("add unsafe ExecStop");
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("source contract must fail before systemctl")
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("source ExecStop must fail closed");

    assert!(error.to_string().contains("privileged auxiliary ExecStop"));
    fixture.assert_files_present();
}

#[test]
fn repeated_uninstall_is_a_real_noop_after_files_and_unit_are_absent() {
    let fixture = UninstallFixture::new();
    let show_count = Cell::new(0_u8);
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        let output = match command(args) {
            Some("show") => {
                let current = show_count.get();
                show_count.set(current + 1);
                match current {
                    0 => managed_show_output(&fixture, "inactive", 0, ""),
                    1 => inhibited_managed_show_output(&fixture, "enabled", "inactive", 0, ""),
                    2 => inhibited_managed_show_output(&fixture, "disabled", "inactive", 0, ""),
                    _ => absent_show_output(),
                }
            }
            _ => command_output(0, "", ""),
        };
        Ok(output)
    };

    let first = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect("first uninstall");
    let second =
        uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
            .expect("repeated uninstall");

    assert!(first.unit_removed && first.env_removed && first.disabled);
    assert!(!second.unit_removed && !second.env_removed && !second.disabled);
    assert!(!second.daemon_reloaded);
    assert_eq!(count_command(&calls.borrow(), "disable"), 2);
    assert_eq!(count_command(&calls.borrow(), "daemon-reload"), 3);
}

#[test]
fn active_service_requires_recursive_cgroup_to_be_empty_after_disable() {
    let fixture = UninstallFixture::new();
    let cgroup_root = fixture.temp.path().join("cgroup");
    let events_file = cgroup_events_file(&cgroup_root);
    fs::create_dir_all(events_file.parent().expect("cgroup parent")).expect("create cgroup path");
    fs::write(&events_file, "populated 1\nfrozen 0\n").expect("write cgroup events");
    let show_count = Cell::new(0_u8);
    let runner = |args: &[String]| {
        let output = match command(args) {
            Some("show") => {
                let current = show_count.get();
                show_count.set(current + 1);
                match current {
                    0 => managed_show_output(&fixture, "active", 42, CONTROL_GROUP),
                    1 => inhibited_managed_show_output(
                        &fixture,
                        "enabled",
                        "active",
                        42,
                        CONTROL_GROUP,
                    ),
                    2 => inhibited_managed_show_output(
                        &fixture,
                        "disabled",
                        "inactive",
                        0,
                        CONTROL_GROUP,
                    ),
                    _ => absent_show_output(),
                }
            }
            Some("disable") => {
                fs::write(&events_file, "populated 0\nfrozen 0\n")
                    .expect("quiesce recursive cgroup");
                command_output(0, "", "")
            }
            _ => command_output(0, "", ""),
        };
        Ok(output)
    };

    let report = uninstall_remote_systemd_with_cgroup_root(
        UNIT,
        &fixture.unit_path,
        &fixture.env_path,
        &cgroup_root,
        &runner,
    )
    .expect("recursive cgroup was stopped");

    assert!(report.unit_removed && report.env_removed);
}

#[test]
fn missing_or_malformed_active_cgroup_evidence_fails_before_disable() {
    for contents in [None, Some("frozen 0\n"), Some("populated unknown\n")] {
        let fixture = UninstallFixture::new();
        let cgroup_root = fixture.temp.path().join("cgroup");
        let events_file = cgroup_events_file(&cgroup_root);
        fs::create_dir_all(events_file.parent().expect("cgroup parent"))
            .expect("create cgroup path");
        if let Some(contents) = contents {
            fs::write(&events_file, contents).expect("write malformed cgroup events");
        }
        let calls = RefCell::new(Vec::new());
        let show_count = Cell::new(0_u8);
        let runner = |args: &[String]| {
            calls.borrow_mut().push(args.to_vec());
            let current = show_count.get();
            show_count.set(current + 1);
            Ok(if current == 0 {
                managed_show_output(&fixture, "active", 42, CONTROL_GROUP)
            } else {
                inhibited_managed_show_output(&fixture, "enabled", "active", 42, CONTROL_GROUP)
            })
        };

        uninstall_remote_systemd_with_cgroup_root(
            UNIT,
            &fixture.unit_path,
            &fixture.env_path,
            &cgroup_root,
            &runner,
        )
        .expect_err("invalid cgroup evidence must fail closed");

        assert_eq!(count_command(&calls.borrow(), "disable"), 0);
        fixture.assert_files_present();
    }
}

#[test]
fn populated_cgroup_after_disable_preserves_managed_files() {
    let fixture = UninstallFixture::new();
    let cgroup_root = fixture.temp.path().join("cgroup");
    let events_file = cgroup_events_file(&cgroup_root);
    fs::create_dir_all(events_file.parent().expect("cgroup parent")).expect("create cgroup path");
    fs::write(&events_file, "populated 1\n").expect("write cgroup events");
    let show_count = Cell::new(0_u8);
    let runner = |args: &[String]| {
        if command(args) == Some("show") {
            let current = show_count.get();
            show_count.set(current + 1);
            return Ok(match current {
                0 => managed_show_output(&fixture, "active", 42, CONTROL_GROUP),
                1 => {
                    inhibited_managed_show_output(&fixture, "enabled", "active", 42, CONTROL_GROUP)
                }
                _ => inhibited_managed_show_output(
                    &fixture,
                    "disabled",
                    "inactive",
                    0,
                    CONTROL_GROUP,
                ),
            });
        }
        Ok(command_output(0, "", ""))
    };

    let error = uninstall_remote_systemd_with_cgroup_root(
        UNIT,
        &fixture.unit_path,
        &fixture.env_path,
        &cgroup_root,
        &runner,
    )
    .expect_err("populated recursive cgroup must block deletion");

    assert!(error.to_string().contains("subtree remains populated"));
    fixture.assert_files_present();
}

struct UninstallFixture {
    temp: TempDir,
    unit_path: PathBuf,
    env_path: PathBuf,
}

impl UninstallFixture {
    fn new() -> Self {
        let temp = trusted_temp();
        let unit_path = temp.path().join("systemd").join(format!("{UNIT}.service"));
        let env_path = temp.path().join("harness").join(format!("{UNIT}.env"));
        fs::create_dir_all(unit_path.parent().expect("unit parent")).expect("unit dir");
        fs::create_dir_all(env_path.parent().expect("environment parent"))
            .expect("environment dir");
        fs::write(
            &unit_path,
            format!(
                "[Service]\nEnvironmentFile={}\nExecStart={BINARY} remote serve\nKillMode=control-group\n\n[Install]\nWantedBy=multi-user.target\n",
                env_path.display()
            ),
        )
        .expect("write managed unit");
        fs::write(&env_path, "HARNESS_REMOTE_TEST=1\n").expect("write environment");
        Self {
            temp,
            unit_path,
            env_path,
        }
    }

    fn assert_files_present(&self) {
        assert!(self.unit_path.is_file());
        assert!(self.env_path.is_file());
    }
}

fn managed_show_output(
    fixture: &UninstallFixture,
    active_state: &str,
    main_pid: u32,
    control_group: &str,
) -> RemoteSystemdCommandOutput {
    show_output(
        "loaded",
        &fixture.unit_path,
        "",
        "enabled",
        active_state,
        main_pid,
        control_group,
    )
}

fn inhibited_managed_show_output(
    fixture: &UninstallFixture,
    unit_file_state: &str,
    active_state: &str,
    main_pid: u32,
    control_group: &str,
) -> RemoteSystemdCommandOutput {
    let inhibitor = inhibitor_path(&fixture.unit_path).expect("inhibitor path");
    show_output(
        "loaded",
        &fixture.unit_path,
        inhibitor.to_str().expect("UTF-8 inhibitor path"),
        unit_file_state,
        active_state,
        main_pid,
        control_group,
    )
}

fn absent_show_output() -> RemoteSystemdCommandOutput {
    show_output("not-found", Path::new(""), "", "", "inactive", 0, "")
}

fn show_output(
    load_state: &str,
    fragment_path: &Path,
    drop_in_paths: &str,
    unit_file_state: &str,
    active_state: &str,
    main_pid: u32,
    control_group: &str,
) -> RemoteSystemdCommandOutput {
    command_output(
        0,
        &format!(
            "Id={UNIT}.service\nNames={UNIT}.service\nLoadState={load_state}\nNeedDaemonReload=no\nFragmentPath={}\nDropInPaths={drop_in_paths}\nUnitFileState={unit_file_state}\nActiveState={active_state}\nMainPID={main_pid}\nControlGroup={control_group}\nKillMode=control-group\nExecStart={{ path={BINARY} ; argv[]={BINARY} remote serve ; }}\nExecStartPre=\nExecStartPost=\nExecCondition=\nExecReload=\nExecStop=\nExecStopPost=\n",
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

fn cgroup_events_file(root: &Path) -> PathBuf {
    root.join("system.slice")
        .join("harness-remote-daemon.service")
        .join("cgroup.events")
}
