use std::cell::RefCell;
use std::path::PathBuf;

use clap::Parser;
use tempfile::tempdir;

use super::super::remote_systemd::{DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, effective_install_show_for_tests, install_remote_systemd_with,
};
use super::super::remote_systemd_upgrade_lifecycle::notify_unit_contents_for_tests;
use super::trusted_test_executable;

#[test]
fn remote_systemd_install_enables_and_starts_remote_serve() {
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
        trusted_test_executable(temp.path()),
        unit_path,
        env_path,
    )
    .expect("systemd install plan");
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| {
        calls.borrow_mut().push(args.to_vec());
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: if args.first().map(String::as_str) == Some("show") {
                effective_install_show_for_tests(&plan)
            } else {
                String::new()
            },
            stderr: String::new(),
        })
    };

    let report = install_remote_systemd_with(&plan, &runner).expect("install systemd");

    assert!(report.enabled);
    assert!(report.started);
    assert_eq!(
        calls.borrow().as_slice(),
        [
            vec!["daemon-reload".to_string()],
            vec![
                "show".to_string(),
                "--property=LoadState".to_string(),
                "--property=FragmentPath".to_string(),
                "--property=DropInPaths".to_string(),
                "--".to_string(),
                "harness-remote-daemon.service".to_string(),
            ],
            vec![
                "enable".to_string(),
                "--now".to_string(),
                "--".to_string(),
                "harness-remote-daemon.service".to_string(),
            ],
        ]
    );
}

#[test]
fn remote_systemd_install_unit_is_upgrade_canonical() {
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
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("systemd install plan");

    assert_eq!(
        notify_unit_contents_for_tests(&plan.unit_contents).expect("canonical notify unit"),
        plan.unit_contents
    );
}

#[test]
fn remote_systemd_plan_runs_aftermarket_dns01() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--acme-challenge",
        "dns",
        "--acme-dns-provider",
        "aftermarket",
    ]);
    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("systemd install plan");

    assert!(plan.unit_contents.contains("--acme-challenge dns"));
    assert!(
        plan.unit_contents
            .contains("--acme-dns-provider aftermarket")
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
fn remote_systemd_plan_rejects_binary_and_environment_inside_dynamic_user_state() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);
    let state_directory = PathBuf::from("/var/lib/private/harness-remote-daemon");

    for (label, binary_path, environment_path) in [
        (
            "binary",
            state_directory.join("bin/harness"),
            PathBuf::from("/etc/harness/harness-remote-daemon.env"),
        ),
        (
            "environment",
            PathBuf::from("/usr/local/bin/harness"),
            state_directory.join("harness.env"),
        ),
    ] {
        let error = RemoteSystemdInstallPlan::for_tests(
            &args,
            binary_path,
            PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
            environment_path,
        )
        .expect_err("reject path inside DynamicUser state directory");

        assert!(
            error.to_string().contains(&format!(
                "systemd {label} path must be outside DynamicUser state directory"
            )),
            "{error}"
        );
    }
}

#[test]
fn remote_systemd_plan_rejects_control_characters_in_remote_values() {
    assert_control_character_rejected(
        &install_args([
            "test",
            "--domain",
            "daemon\nexample.com",
            "--acme-email",
            "ops@example.com",
        ]),
        "systemd domain contains control characters",
    );
    assert_control_character_rejected(
        &install_args([
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
        &install_args([
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

fn assert_control_character_rejected(args: &DaemonRemoteSystemdInstallArgs, expected: &str) {
    let error = RemoteSystemdInstallPlan::for_tests(
        args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect_err("reject control characters");

    assert!(error.to_string().contains(expected), "{expected}: {error}");
}
