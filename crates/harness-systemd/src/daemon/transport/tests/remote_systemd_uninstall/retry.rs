use super::*;

use crate::daemon::transport::remote_systemd_start_permit::{
    install_runtime_start_permit, require_runtime_start_permit_absent,
};

#[test]
fn uninstall_cleans_a_stale_exact_runtime_start_permit_before_source_proof() {
    let fixture = UninstallFixture::new();
    let permit =
        install_runtime_start_permit(&fixture.unit_path).expect("install runtime start permit");
    drop(permit);
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

    let report =
        uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
            .expect("uninstall after stale runtime permit cleanup");

    assert!(report.unit_removed && report.env_removed && report.disabled);
    require_runtime_start_permit_absent(&fixture.unit_path).expect("runtime permit removed");
    assert_eq!(
        calls.borrow().first().and_then(|args| command(args)),
        Some("daemon-reload")
    );
}

#[test]
fn retry_finishes_persistently_inhibited_uninstall_after_reload_failure() {
    let fixture = UninstallFixture::new();
    let disabled = Cell::new(false);
    let removal_reloaded = Cell::new(false);
    let fail_reload = Cell::new(true);
    let runner = |args: &[String]| {
        Ok(retry_output(
            &fixture,
            &disabled,
            &removal_reloaded,
            &fail_reload,
            args,
        ))
    };

    uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("injected reload failure must interrupt uninstall");
    assert!(!fixture.unit_path.exists() && !fixture.env_path.exists());
    assert!(inhibitor_is_installed(&fixture.unit_path).expect("persistent inhibitor"));

    let report =
        uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
            .expect("retry finishes inhibited uninstall");

    assert!(!report.unit_removed && !report.env_removed);
    assert!(report.disabled && report.daemon_reloaded);
    assert!(!inhibitor_is_installed(&fixture.unit_path).expect("inhibitor removed"));
}

fn retry_output(
    fixture: &UninstallFixture,
    disabled: &Cell<bool>,
    removal_reloaded: &Cell<bool>,
    fail_reload: &Cell<bool>,
    args: &[String],
) -> RemoteSystemdCommandOutput {
    match command(args) {
        Some("show") => retry_show_output(fixture, disabled, removal_reloaded),
        Some("disable") => {
            disabled.set(true);
            command_output(0, "", "")
        }
        Some("daemon-reload") => retry_reload_output(fixture, removal_reloaded, fail_reload),
        _ => command_output(0, "", ""),
    }
}

fn retry_show_output(
    fixture: &UninstallFixture,
    disabled: &Cell<bool>,
    removal_reloaded: &Cell<bool>,
) -> RemoteSystemdCommandOutput {
    if fixture.unit_path.exists() {
        return installed_retry_show_output(fixture, disabled.get());
    }
    if removal_reloaded.get() {
        absent_show_output()
    } else {
        inhibited_managed_show_output(fixture, "disabled", "inactive", 0, "")
    }
}

fn installed_retry_show_output(
    fixture: &UninstallFixture,
    disabled: bool,
) -> RemoteSystemdCommandOutput {
    if inhibitor_is_installed(&fixture.unit_path).expect("inspect inhibitor") {
        let state = if disabled { "disabled" } else { "enabled" };
        inhibited_managed_show_output(fixture, state, "inactive", 0, "")
    } else {
        managed_show_output(fixture, "inactive", 0, "")
    }
}

fn retry_reload_output(
    fixture: &UninstallFixture,
    removal_reloaded: &Cell<bool>,
    fail_reload: &Cell<bool>,
) -> RemoteSystemdCommandOutput {
    if !fixture.unit_path.exists() && fail_reload.replace(false) {
        return command_output(5, "", "injected reload failure");
    }
    if !fixture.unit_path.exists() {
        removal_reloaded.set(true);
    }
    command_output(0, "", "")
}

#[test]
fn absent_files_with_hidden_vendor_unit_remain_inhibited() {
    let fixture = UninstallFixture::new();
    fs::remove_file(&fixture.env_path).expect("remove environment");
    fs::remove_file(&fixture.unit_path).expect("remove unit");
    let inhibitor = install_inhibitor(&fixture.unit_path).expect("install inhibitor");
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        Ok(show_output(
            "loaded",
            Path::new("/usr/lib/systemd/system/harness-remote-daemon.service"),
            inhibitor.to_str().expect("UTF-8 inhibitor path"),
            "disabled",
            "inactive",
            0,
            "",
        ))
    };

    let error = uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("hidden vendor unit must remain inhibited");

    assert!(error.to_string().contains("untracked"));
    assert_eq!(count_command(&calls.borrow(), "daemon-reload"), 1);
    assert!(inhibitor_is_installed(&fixture.unit_path).expect("inhibitor retained"));
}

#[test]
fn failed_final_release_reload_restores_the_persistent_inhibitor_for_retry() {
    let fixture = UninstallFixture::new();
    fs::remove_file(&fixture.env_path).expect("remove environment");
    fs::remove_file(&fixture.unit_path).expect("remove unit");
    install_inhibitor(&fixture.unit_path).expect("install inhibitor");
    let fail_release_reload = Cell::new(true);
    let runner = |args: &[String]| {
        if command(args) == Some("daemon-reload")
            && !inhibitor_is_installed(&fixture.unit_path).expect("inspect inhibitor")
            && fail_release_reload.replace(false)
        {
            return Ok(command_output(5, "", "injected final release failure"));
        }
        Ok(match command(args) {
            Some("show") => absent_show_output(),
            _ => command_output(0, "", ""),
        })
    };

    uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
        .expect_err("failed final reload must interrupt uninstall");
    assert!(inhibitor_is_installed(&fixture.unit_path).expect("restored inhibitor"));

    let report =
        uninstall_remote_systemd_with(UNIT, &fixture.unit_path, &fixture.env_path, &runner)
            .expect("retry releases the inhibitor after exact absence proof");

    assert!(report.disabled && report.daemon_reloaded);
    assert!(!inhibitor_is_installed(&fixture.unit_path).expect("released inhibitor"));
}
