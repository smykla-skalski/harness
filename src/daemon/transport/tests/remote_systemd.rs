use std::path::PathBuf;

use clap::Parser;
use tempfile::tempdir;

use super::super::remote::DaemonRemoteCommand;
use super::super::remote_systemd::{DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput,
    install_remote_systemd_with, uninstall_remote_systemd_with,
};

#[derive(Debug, Parser)]
struct DaemonRemoteCommandTestHarness {
    #[command(subcommand)]
    command: DaemonRemoteCommand,
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

    match parsed {
        DaemonRemoteCommand::InstallSystemd(args) => {
            assert_eq!(args.systemd.unit, "harness-remote");
            assert_eq!(
                args.binary_path,
                Some(PathBuf::from("/usr/local/bin/harness"))
            );
            assert!(args.dry_run);
            assert!(args.json);
            assert_eq!(args.serve.domain, "daemon.example.com");
            assert_eq!(args.serve.acme_email, "ops@example.com");
        }
        other => panic!("expected install-systemd, got {other:?}"),
    }
}

#[test]
fn remote_systemd_unit_is_hardened_and_runs_remote_serve() {
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

    assert!(plan.needs_bind_capability);
    assert!(plan.unit_contents.contains(
        "ExecStart=/usr/local/bin/harness daemon remote serve --domain daemon.example.com"
    ));
    assert!(plan.unit_contents.contains("--https-port 443"));
    assert!(plan.unit_contents.contains("--http-port 80"));
    assert!(plan.unit_contents.contains("--acme-email ops@example.com"));
    assert!(plan.unit_contents.contains("--acme-challenge tls-alpn"));
    assert!(
        plan.unit_contents
            .contains("EnvironmentFile=/etc/harness/harness-remote-daemon.env")
    );
    assert!(
        plan.unit_contents
            .contains("Environment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote-daemon")
    );
    assert!(
        plan.unit_contents
            .contains("Environment=HARNESS_DAEMON_OWNERSHIP=external")
    );
    assert!(plan.unit_contents.contains("NoNewPrivileges=true"));
    assert!(plan.unit_contents.contains("PrivateTmp=true"));
    assert!(plan.unit_contents.contains("ProtectSystem=strict"));
    assert!(plan.unit_contents.contains("ProtectHome=true"));
    assert!(
        plan.unit_contents
            .contains("RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX")
    );
    assert!(
        plan.unit_contents
            .contains("StateDirectory=harness-remote-daemon")
    );
    assert!(plan.unit_contents.contains("StateDirectoryMode=0700"));
    assert!(plan.unit_contents.contains("UMask=0077"));
    assert!(
        plan.unit_contents
            .contains("AmbientCapabilities=CAP_NET_BIND_SERVICE")
    );
    assert!(
        plan.unit_contents
            .contains("CapabilityBoundingSet=CAP_NET_BIND_SERVICE")
    );
}

#[test]
fn remote_systemd_high_ports_omit_bind_capability() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--https-port",
        "8443",
        "--http-port",
        "8080",
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

    assert!(!plan.needs_bind_capability);
    assert!(
        !plan
            .unit_contents
            .contains("AmbientCapabilities=CAP_NET_BIND_SERVICE")
    );
    assert!(
        !plan
            .unit_contents
            .contains("CapabilityBoundingSet=CAP_NET_BIND_SERVICE")
    );
}

#[test]
fn remote_systemd_install_writes_files_with_secret_permissions_idempotently() {
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
        unit_path.clone(),
        env_path.clone(),
    )
    .expect("systemd install plan");
    let runner = |_args: &[String]| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    };

    let first = install_remote_systemd_with(&plan, &runner).expect("first install");
    let second = install_remote_systemd_with(&plan, &runner).expect("second install");

    assert!(first.unit_written);
    assert!(first.env_written);
    assert!(!second.unit_written);
    assert!(!second.env_written);
    assert_eq!(
        std::fs::read_to_string(&unit_path).expect("unit file"),
        plan.unit_contents
    );
    assert_eq!(
        std::fs::read_to_string(&env_path).expect("env file"),
        plan.env_contents
    );
    assert_secret_file_mode(&env_path);
}

#[test]
fn remote_systemd_uninstall_is_idempotent() {
    let temp = tempdir().expect("temp dir");
    let unit_path = temp
        .path()
        .join("systemd")
        .join("harness-remote-daemon.service");
    let env_path = temp.path().join("harness").join("remote-daemon.env");
    std::fs::create_dir_all(unit_path.parent().expect("unit parent")).expect("unit dir");
    std::fs::create_dir_all(env_path.parent().expect("env parent")).expect("env dir");
    std::fs::write(&unit_path, "unit").expect("write unit");
    std::fs::write(&env_path, "env").expect("write env");
    let runner = |_args: &[String]| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    };

    let first =
        uninstall_remote_systemd_with("harness-remote-daemon", &unit_path, &env_path, &runner)
            .expect("first uninstall");
    let second =
        uninstall_remote_systemd_with("harness-remote-daemon", &unit_path, &env_path, &runner)
            .expect("second uninstall");

    assert!(first.unit_removed);
    assert!(first.env_removed);
    assert!(!second.unit_removed);
    assert!(!second.env_removed);
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
fn assert_secret_file_mode(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt as _;

    let mode = std::fs::metadata(path)
        .expect("env metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600);
}

#[cfg(not(unix))]
fn assert_secret_file_mode(_path: &std::path::Path) {}
