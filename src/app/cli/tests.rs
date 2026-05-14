use std::path::Path;

use clap::{CommandFactory, error::ErrorKind};

use super::*;
use crate::agents::transport::AgentPromptSubmitArgs;
use crate::daemon::bridge::BridgeCapability;
use crate::daemon::transport::{DaemonCommand, HARNESS_MONITOR_APP_GROUP_ID};
use crate::hooks::adapters::HookAgent;
use crate::observe::{ObserveArgs, ObserveMode};
use crate::run::{
    ApiArgs, ApiMethod, DoctorArgs, EnvoyCommand, FinishArgs, KumaCommand, KumactlArgs,
    KumactlCommand, RepairArgs, ReportCommand, ResumeArgs, StartArgs,
};
use crate::session::transport::{SessionCommand, SessionObserveArgs};
use crate::setup::{CapabilitiesArgs, ClusterArgs, GatewayArgs, KumaSetupCommand};
use crate::task_board::transport::{TaskBoardCommand, TaskBoardOrchestratorCommand};
use crate::task_board::types::TaskBoardStatus;

#[path = "tests/create.rs"]
mod create;
#[path = "tests/daemon.rs"]
mod daemon;
#[path = "tests/observe.rs"]
mod observe;
#[path = "tests/run.rs"]
mod run;
#[path = "tests/session.rs"]
mod session;
#[path = "tests/session_adopt.rs"]
mod session_adopt;
#[path = "tests/session_improver.rs"]
mod session_improver;
#[path = "tests/session_join.rs"]
mod session_join;
#[path = "tests/session_review.rs"]
mod session_review;
#[path = "tests/session_task.rs"]
mod session_task;
#[path = "tests/setup.rs"]
mod setup;

fn expect_cluster_args(command: Command) -> ClusterArgs {
    match command {
        Command::Setup {
            command: SetupCommand::Kuma(args),
        } => match args.command {
            KumaSetupCommand::Cluster(args) => args,
        },
        _ => panic!("expected Cluster command"),
    }
}

fn assert_remote_cluster_args(args: &ClusterArgs) {
    assert_remote_cluster_core(args);
    assert_remote_cluster_targets(args);
}

fn assert_remote_cluster_core(args: &ClusterArgs) {
    assert_eq!(args.provider.as_deref(), Some("remote"));
    assert_eq!(args.push_prefix.as_deref(), Some("ghcr.io/acme/kuma"));
    assert_eq!(args.push_tag.as_deref(), Some("pr-123"));
    assert_eq!(args.mode, "global-zone-up");
    assert_eq!(args.cluster_name, "kuma-1");
    assert_eq!(args.extra_cluster_names, vec!["kuma-2", "zone-1"]);
}

fn assert_remote_cluster_targets(args: &ClusterArgs) {
    assert_eq!(args.remote.len(), 2);
    assert_first_remote_cluster_target(args);
    assert_second_remote_cluster_target(args);
}

fn assert_first_remote_cluster_target(args: &ClusterArgs) {
    assert_eq!(args.remote[0].name, "kuma-1");
    assert_eq!(args.remote[0].kubeconfig, "/tmp/global.yaml");
    assert_eq!(args.remote[0].context.as_deref(), Some("global"));
}

fn assert_second_remote_cluster_target(args: &ClusterArgs) {
    assert_eq!(args.remote[1].name, "kuma-2");
    assert_eq!(args.remote[1].kubeconfig, "/tmp/zone.yaml");
    assert!(args.remote[1].context.is_none());
}

#[test]
fn all_expected_subcommands_registered() {
    let cmd = Cli::command();
    let names: Vec<&str> = cmd.get_subcommands().map(clap::Command::get_name).collect();
    for expected in [
        "create",
        "hook",
        "observe",
        "pre-compact",
        "run",
        "session-start",
        "session-stop",
        "setup",
        "task-board",
    ] {
        assert!(names.contains(&expected), "missing subcommand: {expected}");
    }
}

#[test]
fn hook_subcommand_lists_all_hooks() {
    let cmd = Cli::command();
    let hook_cmd = cmd
        .get_subcommands()
        .find(|s| s.get_name() == "hook")
        .expect("hook subcommand missing");
    let hook_names: Vec<&str> = hook_cmd
        .get_subcommands()
        .map(clap::Command::get_name)
        .collect();
    for expected in [
        "tool-guard",
        "guard-stop",
        "tool-result",
        "tool-failure",
        "context-agent",
        "validate-agent",
    ] {
        assert!(hook_names.contains(&expected), "missing hook: {expected}");
    }
}

#[test]
fn parse_hook_command() {
    let cli = Cli::try_parse_from(["harness", "hook", "suite:run", "tool-guard"]).unwrap();
    match cli.command {
        Command::Hook(HookArgs { skill, hook, .. }) => {
            assert_eq!(skill, "suite:run");
            assert_eq!(hook.name(), "tool-guard");
        }
        _ => panic!("expected Hook command"),
    }
}

#[test]
fn snapshot_cli_help_text() {
    let mut cmd = Cli::command();
    let mut buf = Vec::new();
    cmd.write_help(&mut buf).expect("render help");
    let help = String::from_utf8(buf).expect("utf8 help");
    insta::assert_snapshot!(help);
}

#[test]
fn snapshot_cli_subcommand_list() {
    let cmd = Cli::command();
    let mut names: Vec<&str> = cmd.get_subcommands().map(clap::Command::get_name).collect();
    names.sort_unstable();
    insta::assert_snapshot!(names.join("\n"));
}

#[test]
fn parse_session_observe_with_poll() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "observe",
        "sess-watch",
        "--poll-interval",
        "5",
        "--json",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: SessionCommand::Observe(args),
        } => {
            assert_eq!(args.session_id, "sess-watch");
            assert_eq!(args.poll_interval, 5);
            assert!(args.json);
        }
        _ => panic!("expected Session Observe"),
    }
}

#[test]
fn parse_task_board_create() {
    let cli = Cli::try_parse_from([
        "harness",
        "task-board",
        "create",
        "--title",
        "Add inbox",
        "--body",
        "Track cross-project work",
        "--priority",
        "high",
        "--agent-mode",
        "interactive",
        "--tag",
        "monitor",
    ])
    .unwrap();
    match cli.command {
        Command::TaskBoard {
            command: TaskBoardCommand::Create(args),
        } => {
            assert_eq!(args.title, "Add inbox");
            assert_eq!(args.body, "Track cross-project work");
            assert_eq!(args.tag, ["monitor"]);
        }
        _ => panic!("expected TaskBoard Create"),
    }
}

#[test]
fn parse_task_board_update_planning_fields() {
    let cli = Cli::try_parse_from([
        "harness",
        "task-board",
        "update",
        "task-1",
        "--status",
        "todo",
        "--planning-summary",
        "Implementation plan accepted.",
        "--approved-by",
        "lead",
    ])
    .unwrap();
    match cli.command {
        Command::TaskBoard {
            command: TaskBoardCommand::Update(args),
        } => {
            assert_eq!(args.id, "task-1");
            assert_eq!(args.status, Some(TaskBoardStatus::Todo));
            assert_eq!(
                args.planning_summary.as_deref(),
                Some("Implementation plan accepted.")
            );
            assert_eq!(args.approved_by.as_deref(), Some("lead"));
        }
        _ => panic!("expected TaskBoard Update"),
    }
}

#[test]
fn parse_task_board_operational_subcommands() {
    for (argv, expected) in [
        (["harness", "task-board", "sync", "--json"], "sync"),
        (["harness", "task-board", "dispatch", "--json"], "dispatch"),
        (["harness", "task-board", "evaluate", "--json"], "evaluate"),
        (["harness", "task-board", "audit", "--json"], "audit"),
        (["harness", "task-board", "project", "--json"], "project"),
        (["harness", "task-board", "machine", "--json"], "machine"),
    ] {
        let cli = Cli::try_parse_from(argv).unwrap();
        match (cli.command, expected) {
            (
                Command::TaskBoard {
                    command: TaskBoardCommand::Sync(args),
                },
                "sync",
            ) => assert!(args.json),
            (
                Command::TaskBoard {
                    command: TaskBoardCommand::Dispatch(args),
                },
                "dispatch",
            ) => assert!(args.json),
            (
                Command::TaskBoard {
                    command: TaskBoardCommand::Evaluate(args),
                },
                "evaluate",
            ) => assert!(args.json),
            (
                Command::TaskBoard {
                    command: TaskBoardCommand::Audit(args),
                },
                "audit",
            ) => assert!(args.json),
            (
                Command::TaskBoard {
                    command: TaskBoardCommand::Project(args),
                },
                "project",
            ) => assert!(args.json),
            (
                Command::TaskBoard {
                    command: TaskBoardCommand::Machine(args),
                },
                "machine",
            ) => assert!(args.json),
            _ => panic!("expected TaskBoard {expected}"),
        }
    }
}

#[test]
fn parse_task_board_orchestrator_controls() {
    let cli = Cli::try_parse_from([
        "harness",
        "task-board",
        "orchestrator",
        "run-once",
        "--apply",
        "--status",
        "todo",
        "--project-dir",
        "/tmp/project",
        "--json",
    ])
    .unwrap();
    match cli.command {
        Command::TaskBoard {
            command:
                TaskBoardCommand::Orchestrator {
                    command: TaskBoardOrchestratorCommand::RunOnce(args),
                },
        } => {
            assert!(args.apply);
            assert_eq!(args.status, Some(TaskBoardStatus::Todo));
            assert_eq!(args.project_dir.as_deref(), Some("/tmp/project"));
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Orchestrator RunOnce"),
    }
}
