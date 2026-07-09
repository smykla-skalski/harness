use std::cell::RefCell;
use std::path::PathBuf;

use clap::Parser;
use tempfile::tempdir;

use super::super::remote_systemd::{DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, install_remote_systemd_with,
};

#[test]
fn remote_systemd_install_enables_without_starting_reserved_serve() {
    let temp = tempdir().expect("temp dir");
    let unit_path = temp
        .path()
        .join("systemd")
        .join("harness-remote-daemon.service");
    let env_path = temp.path().join("harness").join("remote-daemon.env");
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);
    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        unit_path,
        env_path,
    )
    .expect("systemd install plan");
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    };

    let report = install_remote_systemd_with(&plan, &runner).expect("install systemd");

    assert!(report.enabled);
    assert!(!report.started);
    assert_eq!(
        calls.borrow().as_slice(),
        [
            vec!["daemon-reload".to_string()],
            vec![
                "enable".to_string(),
                "harness-remote-daemon.service".to_string(),
            ],
        ]
    );
}

#[test]
fn remote_systemd_plan_rejects_relative_binary_path() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);

    let error = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("target/debug/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect_err("reject relative binary path");

    assert!(
        error
            .to_string()
            .contains("systemd binary path must be absolute")
    );
}

#[test]
fn remote_systemd_plan_rejects_relative_env_path() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);

    let error = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("remote-daemon.env"),
    )
    .expect_err("reject relative environment path");

    assert!(
        error
            .to_string()
            .contains("systemd environment path must be absolute")
    );
}

#[test]
fn remote_systemd_plan_rejects_control_characters_in_remote_values() {
    assert_control_character_rejected(
        install_args([
            "test",
            "--domain",
            "daemon\nexample.com",
            "--acme-email",
            "ops@example.com",
        ]),
        "systemd domain contains control characters",
    );
    assert_control_character_rejected(
        install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--host",
            "0.0.\r0.0",
            "--acme-email",
            "ops@example.com",
        ]),
        "systemd host contains control characters",
    );
    assert_control_character_rejected(
        install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops\nteam@example.com",
        ]),
        "systemd acme email contains control characters",
    );
}

#[test]
fn remote_systemd_plan_rejects_percent_in_env_path() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);

    let error = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/remote%daemon.env"),
    )
    .expect_err("reject percent in environment path");

    assert!(
        error
            .to_string()
            .contains("systemd environment path cannot contain '%'")
    );
}

#[test]
fn remote_systemd_execstart_uses_systemd_double_quotes() {
    let args = install_args([
        "test",
        "--domain",
        "daemon example.com",
        "--acme-email",
        "ops team@example.com",
    ]);

    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("systemd install plan");

    assert!(
        plan.unit_contents
            .contains("--domain \"daemon example.com\" --host")
    );
    assert!(
        plan.unit_contents
            .contains("--acme-email \"ops team@example.com\"")
    );
    assert!(!plan.unit_contents.contains("'daemon example.com'"));
    assert!(!plan.unit_contents.contains("'ops team@example.com'"));
}

#[test]
fn remote_systemd_execstart_escapes_percent_specifiers() {
    let args = install_args([
        "test",
        "--domain",
        "daemon%h.example.com",
        "--acme-email",
        "ops@example.com",
    ]);

    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("systemd install plan");

    assert!(
        plan.unit_contents
            .contains("--domain \"daemon%%h.example.com\" --host")
    );
    assert!(!plan.unit_contents.contains("--domain daemon%h.example.com"));
}

fn install_args<const N: usize>(args: [&str; N]) -> DaemonRemoteSystemdInstallArgs {
    #[derive(Debug, Parser)]
    struct Harness {
        #[command(flatten)]
        args: DaemonRemoteSystemdInstallArgs,
    }

    Harness::try_parse_from(args)
        .expect("parse install args")
        .args
}

fn assert_control_character_rejected(args: DaemonRemoteSystemdInstallArgs, expected: &str) {
    let error = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect_err("reject control characters");

    assert!(
        error.to_string().contains(expected),
        "{expected}: {error}"
    );
}
