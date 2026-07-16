use std::fs;
use std::path::{Path, PathBuf};

use clap::Parser;
use tempfile::tempdir;

use crate::errors::CliError;

use super::super::remote::DaemonRemoteCommand;
use super::super::remote_systemd::{
    DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan, default_env_path_for_tests,
    systemd_daemon_root_for_tests,
};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, effective_install_show_for_tests, install_remote_systemd_with,
};
use super::super::remote_systemd_upgrade::validated_recovery_store_path_for_tests;
use super::trusted_test_executable;

#[derive(Debug, Parser)]
struct DaemonRemoteCommandTestHarness {
    #[command(subcommand)]
    command: DaemonRemoteCommand,
}

#[test]
fn remote_systemd_management_root_uses_private_state_directory() {
    assert_eq!(
        systemd_daemon_root_for_tests("harness-remote-proof").expect("systemd daemon root"),
        PathBuf::from("/var/lib/private/harness-remote-proof/harness/daemon/external")
    );
    assert!(systemd_daemon_root_for_tests("../unsafe").is_err());
    assert!(systemd_daemon_root_for_tests("-unsafe-option").is_err());
}

#[test]
fn recovery_store_rejects_root_and_nested_paths_before_mutation() {
    assert!(validated_recovery_store_path_for_tests(PathBuf::from("/").as_path()).is_err());
    for unit in [".service", "unit.service", "unit.service.service"] {
        assert!(
            validated_recovery_store_path_for_tests(
                PathBuf::from(format!("/var/lib/harness/remote-systemd/{unit}")).as_path()
            )
            .is_err()
        );
    }
    assert!(
        validated_recovery_store_path_for_tests(
            PathBuf::from("/var/lib/harness/remote-systemd/unit/nested").as_path()
        )
        .is_err()
    );
    assert_eq!(
        validated_recovery_store_path_for_tests(
            PathBuf::from("/var/lib/harness/remote-systemd/harness-remote").as_path()
        )
        .expect("valid recovery store"),
        PathBuf::from("/var/lib/harness/remote-systemd/harness-remote")
    );
}

#[test]
fn daemon_remote_install_systemd_parses_remote_serve_contract() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "install-systemd",
        "--unit",
        "harness-remote",
        "--binary-path",
        "/usr/local/bin/harness",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--dry-run",
        "--json",
    ])
    .expect("parse install-systemd")
    .command;

    assert_install_systemd_args(parsed);
}

fn assert_install_systemd_args(parsed: DaemonRemoteCommand) {
    let DaemonRemoteCommand::InstallSystemd(args) = parsed else {
        panic!("expected install-systemd");
    };
    assert_install_systemd_identity(&args);
    assert_install_systemd_flags(&args);
}

fn assert_install_systemd_identity(args: &DaemonRemoteSystemdInstallArgs) {
    assert_eq!(args.systemd.unit, "harness-remote");
    assert_eq!(
        args.binary_path,
        Some(PathBuf::from("/usr/local/bin/harness"))
    );
    assert_eq!(args.serve.domain, "daemon.example.com");
}

fn assert_install_systemd_flags(args: &DaemonRemoteSystemdInstallArgs) {
    assert!(args.dry_run);
    assert!(args.json);
    assert_eq!(args.serve.acme_email, "ops@example.com");
}

#[test]
fn daemon_remote_systemd_lifecycle_parses_custom_env_file() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "uninstall-systemd",
        "--unit",
        "harness-remote",
        "--env-file",
        "/srv/harness/remote.env",
        "--json",
    ])
    .expect("parse uninstall-systemd")
    .command;

    assert_uninstall_systemd_args(parsed);

    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "status",
        "--unit",
        "harness-remote",
        "--env-file",
        "/srv/harness/remote.env",
        "--json",
    ])
    .expect("parse status")
    .command;

    assert_status_args(parsed);
}

fn assert_uninstall_systemd_args(parsed: DaemonRemoteCommand) {
    match parsed {
        DaemonRemoteCommand::UninstallSystemd(args) => {
            assert_eq!(args.unit, "harness-remote");
            assert_eq!(
                args.env_file,
                Some(PathBuf::from("/srv/harness/remote.env"))
            );
            assert!(args.json);
        }
        other => panic!("expected uninstall-systemd, got {other:?}"),
    }
}

fn assert_status_args(parsed: DaemonRemoteCommand) {
    match parsed {
        DaemonRemoteCommand::Status(args) => {
            assert_eq!(args.unit, "harness-remote");
            assert_eq!(
                args.env_file,
                Some(PathBuf::from("/srv/harness/remote.env"))
            );
            assert!(args.json);
        }
        other => panic!("expected status, got {other:?}"),
    }
}

#[test]
fn remote_systemd_execstart_uses_trimmed_remote_serve_config() {
    let args = install_args([
        "test",
        "--domain",
        " daemon.example.com ",
        "--host",
        " 0.0.0.0 ",
        "--acme-email",
        " ops@example.com ",
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
            .contains("--domain daemon.example.com --host 0.0.0.0")
    );
    assert!(plan.unit_contents.contains("--acme-email ops@example.com"));
    assert!(!plan.unit_contents.contains("' daemon.example.com '"));
    assert!(!plan.unit_contents.contains("' ops@example.com '"));
}

#[test]
fn remote_systemd_rejects_binary_path_with_whitespace() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);

    let error = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness remote"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect_err("reject whitespace in binary path");

    assert!(
        error
            .to_string()
            .contains("systemd binary path contains whitespace")
    );
}

#[test]
fn remote_systemd_rejects_env_path_with_whitespace() {
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
        PathBuf::from("/etc/harness/remote daemon.env"),
    )
    .expect_err("reject whitespace in environment path");

    assert!(
        error
            .to_string()
            .contains("systemd environment path contains whitespace")
    );
}

#[test]
fn remote_systemd_default_env_path_strips_service_suffix() {
    let args = install_args([
        "test",
        "--unit",
        "harness-remote-daemon.service",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);
    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        default_env_path_for_tests("harness-remote-daemon.service").expect("default env path"),
    )
    .expect("systemd install plan");

    assert_eq!(plan.unit, "harness-remote-daemon");
    assert!(
        plan.unit_contents
            .contains("Environment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote-daemon")
    );
    assert!(
        plan.unit_contents
            .contains("StateDirectory=harness-remote-daemon")
    );
    assert!(
        !plan
            .unit_contents
            .contains("StateDirectory=harness-remote-daemon.service")
    );
    assert_eq!(
        default_env_path_for_tests("harness-remote-daemon").expect("bare default env path"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env")
    );
    assert_eq!(
        default_env_path_for_tests("harness-remote-daemon.service")
            .expect("suffixed default env path"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env")
    );
}

#[test]
fn remote_systemd_status_rejects_unsafe_unit_name() {
    let error = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "status",
        "--unit",
        "../harness-remote-daemon",
    ])
    .expect_err("reject unsafe unit during parsing");

    assert!(error.to_string().contains("unsafe or noncanonical"));
}

#[test]
fn remote_systemd_install_preserves_preprovisioned_environment_idempotently() {
    let temp = tempdir().expect("temp dir");
    let unit_path = temp
        .path()
        .join("systemd")
        .join("harness-remote-daemon.service");
    let env_path = temp.path().join("harness").join("remote-daemon.env");
    fs::create_dir_all(unit_path.parent().expect("unit parent")).expect("unit dir");
    fs::create_dir_all(env_path.parent().expect("env parent")).expect("env dir");
    let provisioned_env = concat!(
        "HARNESS_REMOTE_ACME_DIRECTORY_URL=",
        "https://acme-staging-v02.api.letsencrypt.org/directory\n",
        "HARNESS_REMOTE_ACME_DNS_EXEC=/usr/local/bin/harness-acme-dns\n",
    );
    fs::write(&env_path, provisioned_env).expect("write provisioned env");
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
        unit_path.clone(),
        env_path.clone(),
    )
    .expect("systemd install plan");
    let runner = |systemctl_args: &[String]| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: if systemctl_args.first().map(String::as_str) == Some("show") {
                effective_install_show_for_tests(&plan)
            } else {
                String::new()
            },
            stderr: String::new(),
        })
    };

    let first = install_remote_systemd_with(&plan, &runner).expect("first install");
    let second = install_remote_systemd_with(&plan, &runner).expect("second install");

    assert!(first.unit_written);
    assert!(!first.env_written);
    assert!(!second.unit_written);
    assert!(!second.env_written);
    assert_eq!(
        fs::read_to_string(&unit_path).expect("unit file"),
        plan.unit_contents
    );
    assert_eq!(
        fs::read_to_string(&env_path).expect("env file"),
        provisioned_env
    );
    assert_secret_file_mode(&env_path);
}

#[test]
fn remote_systemd_install_refuses_legacy_readiness_conversion_before_mutation() {
    let temp = tempdir().expect("temp dir");
    let unit_path = temp.path().join("systemd").join("remote.service");
    let env_path = temp.path().join("harness").join("remote.env");
    fs::create_dir_all(unit_path.parent().expect("unit parent")).expect("unit dir");
    fs::create_dir_all(env_path.parent().expect("env parent")).expect("env dir");
    let legacy = "[Unit]\nDescription=legacy\n[Service]\nType=simple\nExecStart=/bin/false\n";
    fs::write(&unit_path, legacy).expect("write legacy unit");
    fs::write(&env_path, "KEEP=1\n").expect("write environment");
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
        unit_path.clone(),
        env_path.clone(),
    )
    .expect("systemd install plan");
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("legacy refusal must happen before systemctl")
    };

    let error = install_remote_systemd_with(&plan, &runner)
        .expect_err("legacy unit requires transactional upgrade");

    assert!(error.to_string().contains("use harness-systemd upgrade"));
    assert_eq!(fs::read_to_string(&unit_path).expect("legacy unit"), legacy);
    assert_eq!(
        fs::read_to_string(&env_path).expect("environment"),
        "KEEP=1\n"
    );
}

#[test]
fn remote_systemd_install_refuses_notify_unit_drift_before_mutation() {
    let temp = tempdir().expect("temp dir");
    let unit_path = temp.path().join("systemd").join("remote.service");
    let env_path = temp.path().join("harness").join("remote.env");
    fs::create_dir_all(unit_path.parent().expect("unit parent")).expect("unit dir");
    fs::create_dir_all(env_path.parent().expect("env parent")).expect("env dir");
    let drifted = "[Service]\nType=notify\nNotifyAccess=main\nExecStart=/bin/false\n";
    fs::write(&unit_path, drifted).expect("write drifted unit");
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
        unit_path.clone(),
        env_path,
    )
    .expect("systemd install plan");
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("unit drift refusal must happen before systemctl")
    };

    let error = install_remote_systemd_with(&plan, &runner)
        .expect_err("notify unit drift requires transactional upgrade");

    assert!(error.to_string().contains("differs"));
    assert_eq!(
        fs::read_to_string(&unit_path).expect("drifted unit"),
        drifted
    );
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

#[cfg(unix)]
fn assert_secret_file_mode(path: &Path) {
    use std::os::unix::fs::PermissionsExt as _;

    let mode = fs::metadata(path)
        .expect("env metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600);
}

#[cfg(not(unix))]
fn assert_secret_file_mode(_path: &Path) {}
