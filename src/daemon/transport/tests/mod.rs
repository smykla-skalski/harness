mod cli;
mod lifecycle;

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
        "sess-123",
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
    temp_env::with_var("HARNESS_APP_GROUP_ID", Option::<&str>::None, || {
        let plan = dev_args.spawn_plan();
        assert_eq!(
            plan.args,
            vec![
                "daemon".to_string(),
                "serve".to_string(),
                "--host".to_string(),
                "127.0.0.1".to_string(),
                "--port".to_string(),
                "8123".to_string(),
                "--codex-ws-url".to_string(),
                "ws://127.0.0.1:7777".to_string(),
            ]
        );
        assert_eq!(
            plan.set_env,
            vec![(
                "HARNESS_APP_GROUP_ID".to_string(),
                "com.example.group".to_string(),
            )]
        );
        assert_eq!(plan.unset_env, vec!["HARNESS_SANDBOXED".to_string()]);
    });

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
            assert_eq!(args.session, "sess-123");
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
