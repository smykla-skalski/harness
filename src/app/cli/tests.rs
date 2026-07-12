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
use crate::task_board::types::{ExternalRefProvider, TaskBoardStatus, TaskBoardWorkflowStatus};

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
        "--external-ref",
        "github:42=https://example.invalid/issues/42",
        "--session-id",
        "session-1",
        "--work-item-id",
        "work-1",
    ])
    .unwrap();
    match task_board_command(cli.command) {
        TaskBoardCommand::Create(args) => {
            assert_eq!(args.title, "Add inbox");
            assert_eq!(args.body, "Track cross-project work");
            assert_eq!(args.tag, ["monitor"]);
            let external_ref = args.fields.external_ref[0].as_external_ref();
            assert_eq!(external_ref.provider, ExternalRefProvider::GitHub);
            assert_eq!(external_ref.external_id, "42");
            assert_eq!(args.fields.session_id.as_deref(), Some("session-1"));
            assert_eq!(args.fields.work_item_id.as_deref(), Some("work-1"));
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
        "--workflow-status",
        "running",
        "--workflow-branch",
        "feature/task-1",
        "--workflow-policy-trace-id",
        "trace-1",
        "--clear-session",
        "--clear-work-item",
    ])
    .unwrap();
    match task_board_command(cli.command) {
        TaskBoardCommand::Update(args) => {
            assert_eq!(args.id, "task-1");
            assert_eq!(args.status, Some(TaskBoardStatus::Todo));
            assert_eq!(
                args.fields.planning_summary.as_deref(),
                Some("Implementation plan accepted.")
            );
            assert_eq!(args.fields.approved_by.as_deref(), Some("lead"));
            assert_eq!(
                args.fields.workflow_status,
                Some(TaskBoardWorkflowStatus::Running)
            );
            assert!(args.clear_links.clear_session);
            assert!(args.clear_links.clear_work_item);
        }
        _ => panic!("expected TaskBoard Update"),
    }
}

#[test]
fn parse_task_board_orchestrator_runtime_config_and_tokens() {
    let runtime_config = Cli::try_parse_from([
        "harness",
        "task-board",
        "orchestrator",
        "runtime-config",
        "--repository",
        "owner/repo",
        "--author-email",
        "repo@example.com",
        "--signing-mode",
        "gpg",
        "--gpg-key-id",
        "ABC123",
        "--json",
    ])
    .unwrap();
    match task_board_command(runtime_config.command) {
        TaskBoardCommand::Orchestrator {
            command: TaskBoardOrchestratorCommand::RuntimeConfig(args),
        } => {
            assert_eq!(args.repository.as_deref(), Some("owner/repo"));
            assert_eq!(
                args.identity.author_email.as_deref(),
                Some("repo@example.com")
            );
            assert!(args.signing.signing_mode.is_some());
            assert_eq!(args.signing.gpg_key_id.as_deref(), Some("ABC123"));
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Orchestrator RuntimeConfig"),
    }

    let tokens = Cli::try_parse_from([
        "harness",
        "task-board",
        "orchestrator",
        "github-tokens",
        "--global-token-env",
        "HARNESS_TOKEN",
        "--repository-token-env",
        "owner/repo=HARNESS_REPO_TOKEN",
    ])
    .unwrap();
    match task_board_command(tokens.command) {
        TaskBoardCommand::Orchestrator {
            command: TaskBoardOrchestratorCommand::GithubTokens(args),
        } => {
            assert_eq!(args.global_token_env.as_deref(), Some("HARNESS_TOKEN"));
            assert_eq!(args.repository_token_env, ["owner/repo=HARNESS_REPO_TOKEN"]);
        }
        _ => panic!("expected TaskBoard Orchestrator GithubTokens"),
    }

    let todoist = Cli::try_parse_from([
        "harness",
        "task-board",
        "orchestrator",
        "todoist-token",
        "--token-env",
        "HARNESS_TODOIST_TOKEN",
        "--json",
    ])
    .unwrap();
    match task_board_command(todoist.command) {
        TaskBoardCommand::Orchestrator {
            command: TaskBoardOrchestratorCommand::TodoistToken(args),
        } => {
            assert_eq!(args.token_env.as_deref(), Some("HARNESS_TODOIST_TOKEN"));
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Orchestrator TodoistToken"),
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
        match (task_board_command(cli.command), expected) {
            (TaskBoardCommand::Sync(args), "sync") => assert!(args.json),
            (TaskBoardCommand::Dispatch(args), "dispatch") => assert!(args.json),
            (TaskBoardCommand::Evaluate(args), "evaluate") => assert!(args.json),
            (TaskBoardCommand::Audit(args), "audit") => assert!(args.json),
            (TaskBoardCommand::Project(args), "project") => assert!(args.json),
            (TaskBoardCommand::Machine(args), "machine") => assert!(args.json),
            _ => panic!("expected TaskBoard {expected}"),
        }
    }
}

#[test]
fn task_board_commands_reject_removed_board_root_override() {
    let error = Cli::try_parse_from([
        "harness",
        "task-board",
        "list",
        "--board-root",
        "/tmp/task-board",
    ])
    .expect_err("task-board storage must not be caller-selectable");

    assert_eq!(error.kind(), ErrorKind::UnknownArgument);
}

#[test]
fn parse_task_board_planning_transitions() {
    let begin = Cli::try_parse_from(["harness", "task-board", "begin", "task-1"]).unwrap();
    match task_board_command(begin.command) {
        TaskBoardCommand::Begin(args) => assert_eq!(args.id, "task-1"),
        _ => panic!("expected TaskBoard Begin"),
    }

    let submit = Cli::try_parse_from([
        "harness",
        "task-board",
        "submit",
        "task-1",
        "--summary",
        "Use the documented approach.",
    ])
    .unwrap();
    match task_board_command(submit.command) {
        TaskBoardCommand::Submit(args) => {
            assert_eq!(args.id, "task-1");
            assert_eq!(args.summary, "Use the documented approach.");
        }
        _ => panic!("expected TaskBoard Submit"),
    }

    let approve = Cli::try_parse_from([
        "harness",
        "task-board",
        "approve",
        "task-1",
        "--approved-by",
        "lead",
        "--approved-at",
        "2026-05-14T02:00:00Z",
    ])
    .unwrap();
    match task_board_command(approve.command) {
        TaskBoardCommand::Approve(args) => {
            assert_eq!(args.id, "task-1");
            assert_eq!(args.approved_by, "lead");
            assert_eq!(args.approved_at.as_deref(), Some("2026-05-14T02:00:00Z"));
        }
        _ => panic!("expected TaskBoard Approve"),
    }
}

#[test]
fn parse_task_board_item_scoped_operations() {
    let dispatch = Cli::try_parse_from([
        "harness",
        "task-board",
        "dispatch",
        "--item-id",
        "task-1",
        "--status",
        "todo",
        "--json",
    ])
    .unwrap();
    match task_board_command(dispatch.command) {
        TaskBoardCommand::Dispatch(args) => {
            assert_eq!(args.item_id.as_deref(), Some("task-1"));
            assert_eq!(args.status, Some(TaskBoardStatus::Todo));
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Dispatch"),
    }

    let evaluate =
        Cli::try_parse_from(["harness", "task-board", "evaluate", "--id", "task-2"]).unwrap();
    match task_board_command(evaluate.command) {
        TaskBoardCommand::Evaluate(args) => {
            assert_eq!(args.item_id.as_deref(), Some("task-2"));
        }
        _ => panic!("expected TaskBoard Evaluate"),
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
        "--item-id",
        "task-1",
        "--status",
        "todo",
        "--project-dir",
        "/tmp/project",
        "--json",
    ])
    .unwrap();
    match task_board_command(cli.command) {
        TaskBoardCommand::Orchestrator {
            command: TaskBoardOrchestratorCommand::RunOnce(args),
        } => {
            assert!(args.apply);
            assert_eq!(args.item_id.as_deref(), Some("task-1"));
            assert_eq!(args.status, Some(TaskBoardStatus::Todo));
            assert_eq!(args.project_dir.as_deref(), Some("/tmp/project"));
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Orchestrator RunOnce"),
    }
}

fn task_board_command(command: Command) -> TaskBoardCommand {
    match command {
        Command::TaskBoard { command } => *command,
        _ => panic!("expected TaskBoard command"),
    }
}
