use std::path::PathBuf;

use clap::Parser;

use super::super::remote_systemd::{DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan};

#[test]
fn remote_systemd_unit_is_hardened_and_runs_remote_serve() {
    let plan = hardened_unit_plan();

    assert!(plan.needs_bind_capability);
    assert!(plan.unit_contents.contains(
        "ExecStart=/usr/local/bin/harness-daemon remote serve --domain daemon.example.com"
    ));
    for value in [
        "--https-port 443",
        "--http-port 80",
        "--acme-email ops@example.com",
        "--acme-challenge tls-alpn",
        "EnvironmentFile=/etc/harness/harness-remote-daemon.env",
        "Environment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote-daemon",
        "Environment=XDG_DATA_HOME=%S/harness-remote-daemon",
        "Environment=HARNESS_DAEMON_OWNERSHIP=external",
        "StateDirectory=harness-remote-daemon",
        "StateDirectoryMode=0700",
        "UMask=0077",
        "AmbientCapabilities=CAP_NET_BIND_SERVICE",
        "CapabilityBoundingSet=CAP_NET_BIND_SERVICE",
    ] {
        assert!(plan.unit_contents.contains(value), "missing {value}");
    }

    let required_sandbox = [
        "NoNewPrivileges=true",
        "DynamicUser=yes",
        "PrivateTmp=true",
        "PrivateDevices=true",
        "PrivateMounts=true",
        "ProtectSystem=strict",
        "ProtectHome=true",
        "ProtectClock=true",
        "ProtectControlGroups=true",
        "ProtectHostname=true",
        "ProtectKernelLogs=true",
        "ProtectKernelModules=true",
        "ProtectKernelTunables=true",
        "ProtectProc=invisible",
        "ProcSubset=pid",
        "LockPersonality=true",
        "MemoryDenyWriteExecute=true",
        "RestrictNamespaces=true",
        "RestrictRealtime=true",
        "RestrictSUIDSGID=true",
        "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX",
        "SystemCallArchitectures=native",
        "SystemCallFilter=@system-service",
        "SystemCallFilter=~@privileged @resources",
        "SystemCallErrorNumber=EPERM",
    ];
    let missing = required_sandbox
        .iter()
        .filter(|directive| !plan.unit_contents.contains(*directive))
        .copied()
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "missing sandbox directives: {missing:?}"
    );
    assert!(
        !plan.unit_contents.contains("PrivateUsers=true"),
        "low-port capability must remain in the host user namespace"
    );
}

fn hardened_unit_plan() -> RemoteSystemdInstallPlan {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);
    unit_plan(&args)
}

#[test]
fn remote_systemd_high_ports_isolate_users_without_bind_capability() {
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
    let plan = unit_plan(&args);

    assert!(!plan.needs_bind_capability);
    assert!(plan.unit_contents.contains("PrivateUsers=true"));
    assert!(plan.unit_contents.contains("CapabilityBoundingSet=\n"));
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

fn unit_plan(args: &DaemonRemoteSystemdInstallArgs) -> RemoteSystemdInstallPlan {
    RemoteSystemdInstallPlan::for_tests(
        args,
        PathBuf::from("/usr/local/bin/harness-daemon"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("systemd install plan")
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
