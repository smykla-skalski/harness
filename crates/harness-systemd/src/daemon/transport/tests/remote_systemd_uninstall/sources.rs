use super::*;

#[test]
fn untracked_loaded_unit_is_not_disabled_or_removed() {
    let temp = trusted_temp();
    let unit_path = temp.path().join("remote.service");
    let env_path = temp.path().join("remote.env");
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        Ok(show_output(
            "loaded",
            Path::new("/usr/lib/systemd/system/harness-remote-daemon.service"),
            "",
            "enabled",
            "inactive",
            0,
            "",
        ))
    };

    let error = uninstall_remote_systemd_with(UNIT, &unit_path, &env_path, &runner)
        .expect_err("untracked loaded unit must fail closed");

    assert!(error.to_string().contains("untracked"));
    assert_eq!(count_command(&calls.borrow(), "disable"), 0);
}

#[test]
fn shadowed_managed_unit_is_not_disabled_or_removed() {
    let fixture = UninstallFixture::new();
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        Ok(show_output(
            "loaded",
            Path::new("/usr/lib/systemd/system/harness-remote-daemon.service"),
            "",
            "enabled",
            "inactive",
            0,
            "",
        ))
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("shadowed managed unit must fail closed");

    assert!(error.to_string().contains("unexpected effective sources"));
    assert_eq!(count_command(&calls.borrow(), "disable"), 0);
    fixture.assert_files_present();
}

#[test]
fn managed_unit_with_drop_in_is_not_disabled_or_removed() {
    let fixture = UninstallFixture::new();
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        Ok(show_output(
            "loaded",
            &fixture.unit_path,
            "/etc/systemd/system/harness-remote-daemon.service.d/override.conf",
            "enabled",
            "inactive",
            0,
            "",
        ))
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("managed unit with a drop-in must fail closed");

    assert!(error.to_string().contains("DropInPaths="));
    assert_eq!(count_command(&calls.borrow(), "disable"), 0);
    fixture.assert_files_present();
}

#[test]
fn stale_manager_configuration_is_not_disabled_or_removed() {
    let fixture = UninstallFixture::new();
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        let mut output = managed_show_output(&fixture, "inactive", 0, "");
        output.stdout = output
            .stdout
            .replace("NeedDaemonReload=no", "NeedDaemonReload=yes");
        Ok(output)
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("stale manager state must fail closed");

    assert!(error.to_string().contains("NeedDaemonReload=yes"));
    assert_eq!(count_command(&calls.borrow(), "disable"), 0);
    fixture.assert_files_present();
}

#[test]
fn effective_source_change_after_disable_preserves_managed_files() {
    let fixture = UninstallFixture::new();
    let show_count = Cell::new(0_u8);
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        if command(args) == Some("show") {
            let current = show_count.get();
            show_count.set(current + 1);
            return Ok(match current {
                0 => managed_show_output(&fixture, "inactive", 0, ""),
                1 => inhibited_managed_show_output(&fixture, "enabled", "inactive", 0, ""),
                _ => show_output(
                    "loaded",
                    Path::new("/usr/lib/systemd/system/harness-remote-daemon.service"),
                    inhibitor_path(&fixture.unit_path)
                        .expect("inhibitor path")
                        .to_str()
                        .expect("UTF-8 inhibitor path"),
                    "disabled",
                    "inactive",
                    0,
                    "",
                ),
            });
        }
        Ok(command_output(0, "", ""))
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("effective source change must block removal");

    assert!(error.to_string().contains("unexpected effective sources"));
    assert_eq!(count_command(&calls.borrow(), "disable"), 2);
    fixture.assert_files_present();
}

#[test]
fn persistent_enablement_link_after_disable_preserves_managed_files() {
    let fixture = UninstallFixture::new();
    let wants = fixture
        .unit_path
        .parent()
        .expect("unit parent")
        .join("multi-user.target.wants");
    fs::create_dir(&wants).expect("create wants directory");
    symlink(&fixture.unit_path, wants.join(format!("{UNIT}.service")))
        .expect("create enablement link");
    let calls = RefCell::new(Vec::new());
    let show_count = Cell::new(0_u8);
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        let current = show_count.get();
        show_count.set(current + 1);
        Ok(match current {
            0 => managed_show_output(&fixture, "inactive", 0, ""),
            1 => inhibited_managed_show_output(&fixture, "enabled", "inactive", 0, ""),
            _ => inhibited_managed_show_output(&fixture, "disabled", "inactive", 0, ""),
        })
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("persistent enablement must block removal");

    assert!(error.to_string().contains("remains persistently enabled"));
    assert_eq!(count_command(&calls.borrow(), "disable"), 2);
    fixture.assert_files_present();
}

#[test]
fn effective_exec_stop_fails_before_inhibitor_install() {
    let fixture = UninstallFixture::new();
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        let mut output = managed_show_output(&fixture, "inactive", 0, "");
        output.stdout = output.stdout.replace(
            "ExecStop=\n",
            "ExecStop={ path=/bin/sh ; argv[]=/bin/sh -c true ; }\n",
        );
        Ok(output)
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("effective ExecStop must fail closed");

    assert!(error.to_string().contains("ExecStop="));
    assert_eq!(count_command(&calls.borrow(), "daemon-reload"), 0);
    fixture.assert_files_present();
}
