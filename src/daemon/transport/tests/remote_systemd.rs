use std::path::PathBuf;

use clap::Parser;
use tempfile::tempdir;

use super::super::remote::DaemonRemoteCommand;
use super::super::remote_systemd::{
    DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan, default_env_path_for_tests,
    systemd_daemon_root_for_tests,
};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, install_remote_systemd_with, uninstall_remote_systemd_with,
};

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
            .contains("Environment=XDG_DATA_HOME=%S/harness-remote-daemon")
    );
    assert!(
        plan.unit_contents
            .contains("Environment=HARNESS_DAEMON_OWNERSHIP=external")
    );
    assert!(plan.unit_contents.contains("NoNewPrivileges=true"));
    assert!(plan.unit_contents.contains("DynamicUser=yes"));
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
        default_env_path_for_tests("harness-remote-daemon.service"),
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
        default_env_path_for_tests("harness-remote-daemon"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env")
    );
    assert_eq!(
        default_env_path_for_tests("harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env")
    );
}

#[test]
fn remote_systemd_status_rejects_unsafe_unit_name() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "status",
        "--unit",
        "../harness-remote-daemon",
    ])
    .expect("parse status")
    .command;

    let DaemonRemoteCommand::Status(args) = parsed else {
        panic!("expected status");
    };

    assert!(args.validate_for_tests().is_err());
}

#[test]
fn remote_systemd_uninstall_reports_disable_failure() {
    let temp = tempdir().expect("temp dir");
    let unit_path = temp.path().join("systemd").join("remote.service");
    let env_path = temp.path().join("harness").join("remote.env");
    std::fs::create_dir_all(unit_path.parent().expect("unit parent")).expect("unit dir");
    std::fs::create_dir_all(env_path.parent().expect("env parent")).expect("env dir");
    std::fs::write(&unit_path, "unit").expect("write unit");
    std::fs::write(&env_path, "env").expect("write env");
    let runner = |args: &[String]| {
        if args.first().map(String::as_str) == Some("disable") {
            return Ok(RemoteSystemdCommandOutput {
                exit_code: 5,
                stdout: String::new(),
                stderr: "unit not loaded".to_string(),
            });
        }
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    };

    let report = uninstall_remote_systemd_with("remote", &unit_path, &env_path, &runner)
        .expect("uninstall continues after disable failure");

    assert!(!report.disabled);
    assert_eq!(report.disable_exit_code, Some(5));
    assert_eq!(report.disable_error.as_deref(), Some("unit not loaded"));
    assert!(report.unit_removed);
    assert!(report.env_removed);
    assert!(report.daemon_reloaded);
}

#[test]
fn remote_systemd_install_preserves_preprovisioned_environment_idempotently() {
    let temp = tempdir().expect("temp dir");
    let unit_path = temp
        .path()
        .join("systemd")
        .join("harness-remote-daemon.service");
    let env_path = temp.path().join("harness").join("remote-daemon.env");
    std::fs::create_dir_all(unit_path.parent().expect("unit parent")).expect("unit dir");
    std::fs::create_dir_all(env_path.parent().expect("env parent")).expect("env dir");
    std::fs::write(&unit_path, "stale unit").expect("write stale unit");
    let provisioned_env = concat!(
        "HARNESS_REMOTE_ACME_DIRECTORY_URL=",
        "https://acme-staging-v02.api.letsencrypt.org/directory\n",
        "HARNESS_REMOTE_ACME_DNS_EXEC=/usr/local/bin/harness-acme-dns\n",
    );
    std::fs::write(&env_path, provisioned_env).expect("write provisioned env");
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
    assert!(!first.env_written);
    assert!(!second.unit_written);
    assert!(!second.env_written);
    assert_eq!(
        std::fs::read_to_string(&unit_path).expect("unit file"),
        plan.unit_contents
    );
    assert_eq!(
        std::fs::read_to_string(&env_path).expect("env file"),
        provisioned_env
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
