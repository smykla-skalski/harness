mod cli;
mod lifecycle;
mod remote_acme;
mod remote_cli;
mod remote_clients;

use std::path::{Path, PathBuf};

use clap::Parser;

use super::control::{restart_daemon_with, stop_daemon_with};
use super::{DaemonCommand, HARNESS_MONITOR_APP_GROUP_ID};

#[derive(Debug, Parser)]
struct DaemonCommandTestHarness {
    #[command(subcommand)]
    command: DaemonCommand,
}

#[test]
fn daemon_transport_round_trip_smoke_covers_public_surface() {
    let serve = DaemonCommandTestHarness::try_parse_from([
        "test",
        "serve",
        "--host",
        "0.0.0.0",
        "--port",
        "7777",
        "--refresh-seconds",
        "3",
        "--observe-seconds",
        "7",
        "--sandboxed",
        "--codex-ws-url",
        "ws://127.0.0.1:8899",
    ])
    .expect("parse serve command")
    .command;
    let dev = DaemonCommandTestHarness::try_parse_from([
        "test",
        "dev",
        "--host",
        "127.0.0.1",
        "--port",
        "8123",
        "--app-group-id",
        "com.example.group",
        "--codex-ws-url",
        "ws://127.0.0.1:7777",
    ])
    .expect("parse dev command")
    .command;
    let stop = DaemonCommandTestHarness::try_parse_from(["test", "stop", "--json"])
        .expect("parse stop command")
        .command;
    let restart = DaemonCommandTestHarness::try_parse_from(["test", "restart", "--json"])
        .expect("parse restart command")
        .command;
    let install = DaemonCommandTestHarness::try_parse_from([
        "test",
        "install-launch-agent",
        "--binary-path",
        "/tmp/harness",
        "--json",
    ])
    .expect("parse install command")
    .command;
    let remove =
        DaemonCommandTestHarness::try_parse_from(["test", "remove-launch-agent", "--json"])
            .expect("parse remove command")
            .command;
    let status = DaemonCommandTestHarness::try_parse_from(["test", "status"])
        .expect("parse status command")
        .command;
    let doctor = DaemonCommandTestHarness::try_parse_from(["test", "doctor"])
        .expect("parse doctor command")
        .command;
    let snapshot = DaemonCommandTestHarness::try_parse_from([
        "test",
        "snapshot",
        "--session",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc23",
        "--json",
    ])
    .expect("parse snapshot command")
    .command;

    match serve {
        DaemonCommand::Serve(args) => {
            assert_eq!(args.host, "0.0.0.0");
            assert_eq!(args.port, 7777);
            assert_eq!(args.refresh_seconds, 3);
            assert_eq!(args.observe_seconds, 7);
            assert!(args.sandboxed);
            assert_eq!(args.codex_ws_url.as_deref(), Some("ws://127.0.0.1:8899"));
        }
        other => panic!("expected serve command, got {other:?}"),
    }

    let dev_args = match dev {
        DaemonCommand::Dev(args) => args,
        other => panic!("expected dev command, got {other:?}"),
    };
    assert_eq!(dev_args.app_group_id, "com.example.group");
    assert_eq!(HARNESS_MONITOR_APP_GROUP_ID, "Q498EB36N4.io.harnessmonitor");
    temp_env::with_vars(
        [
            ("HARNESS_APP_GROUP_ID", Option::<&str>::None),
            ("HARNESS_DAEMON_DATA_HOME", Option::<&str>::None),
            ("HOME", Some("/tmp/home")),
            ("HARNESS_HOST_HOME", Some("/tmp/home")),
        ],
        || {
            let plan = dev_args.execution_plan();
            assert_eq!(plan.serve_config.host, "127.0.0.1");
            assert_eq!(plan.serve_config.port, 8123);
            assert_eq!(
                plan.daemon_root,
                PathBuf::from("/tmp/home")
                    .join("Library")
                    .join("Group Containers")
                    .join("com.example.group")
                    .join("harness")
                    .join("daemon")
                    .join("external")
            );
            assert_eq!(
                plan.log_effective_app_group.as_deref(),
                Some("com.example.group")
            );
        },
    );

    match stop {
        DaemonCommand::Stop(args) => assert!(args.json),
        other => panic!("expected stop command, got {other:?}"),
    }
    match restart {
        DaemonCommand::Restart(args) => assert!(args.json),
        other => panic!("expected restart command, got {other:?}"),
    }
    match install {
        DaemonCommand::InstallLaunchAgent(args) => {
            assert_eq!(args.binary_path, Some(PathBuf::from("/tmp/harness")));
            assert!(args.json);
        }
        other => panic!("expected install command, got {other:?}"),
    }
    match remove {
        DaemonCommand::RemoveLaunchAgent(args) => assert!(args.json),
        other => panic!("expected remove command, got {other:?}"),
    }
    assert!(matches!(status, DaemonCommand::Status));
    assert!(matches!(doctor, DaemonCommand::Doctor));
    match snapshot {
        DaemonCommand::Snapshot(args) => {
            assert_eq!(args.session, "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc23");
            assert!(args.json);
        }
        other => panic!("expected snapshot command, got {other:?}"),
    }

    let stopped = stop_daemon_with(
        false,
        &lifecycle::sample_launch_agent_status(false, false),
        || panic!("manual stop smoke should not read a manifest"),
        || panic!("manual stop smoke should not boot out launchd"),
        || Ok(false),
        |_endpoint| panic!("manual stop smoke should not wait for launchd shutdown"),
    )
    .expect("manual stop smoke");
    assert_eq!(stopped.status, "stopped");

    let restarted = restart_daemon_with(
        false,
        &lifecycle::sample_launch_agent_status(false, false),
        Path::new("/tmp/harness"),
        || panic!("manual restart smoke should not read a manifest"),
        || panic!("manual restart smoke should not boot out launchd"),
        || Ok(true),
        |_endpoint| panic!("manual restart smoke should not wait for launchd shutdown"),
        || panic!("manual restart smoke should not restart launchd"),
        |_binary| Ok(()),
        || panic!("manual restart smoke should not wait for launchd health"),
    )
    .expect("manual restart smoke");
    assert_eq!(restarted.status, "restarted");
}
