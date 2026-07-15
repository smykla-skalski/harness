use clap::{Parser, error::ErrorKind};

use super::{Cli, task_board_command};
use crate::task_board::transport::{
    TaskBoardCommand, TaskBoardOrchestratorCommand, TaskBoardPolicyCommand,
};

#[test]
fn parse_task_board_manual_dispatch_steps() {
    let pick = Cli::try_parse_from(["harness", "task-board", "dispatch-pick", "--json"])
        .expect("parse dispatch pick");
    match task_board_command(pick.command) {
        TaskBoardCommand::DispatchPick(args) => assert!(args.json),
        _ => panic!("expected TaskBoard DispatchPick"),
    }

    let deliver = Cli::try_parse_from([
        "harness",
        "task-board",
        "dispatch-deliver",
        "--item-id",
        "task-1",
        "--dry-run",
        "--json",
    ])
    .expect("parse dispatch deliver");
    match task_board_command(deliver.command) {
        TaskBoardCommand::DispatchDeliver(args) => {
            assert_eq!(args.item_id, "task-1");
            assert!(args.dry_run);
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard DispatchDeliver"),
    }
}

#[test]
fn parse_orchestrator_step_mode() {
    let cli = Cli::try_parse_from([
        "harness",
        "task-board",
        "orchestrator",
        "settings",
        "--step-mode",
        "true",
        "--json",
    ])
    .expect("parse orchestrator step mode");
    match task_board_command(cli.command) {
        TaskBoardCommand::Orchestrator {
            command: TaskBoardOrchestratorCommand::Settings(args),
        } => assert_eq!(args.step_mode, Some(true)),
        _ => panic!("expected TaskBoard Orchestrator Settings"),
    }
}

#[test]
fn parse_policy_grants() {
    let grants = Cli::try_parse_from(["harness", "task-board", "policy", "grants", "--json"])
        .expect("parse policy grants");
    match task_board_command(grants.command) {
        TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::Grants(args),
        } => assert!(args.json),
        _ => panic!("expected TaskBoard Policy Grants"),
    }
}

#[test]
fn parse_policy_grant_resolve() {
    let resolve = Cli::try_parse_from([
        "harness",
        "task-board",
        "policy",
        "grant-resolve",
        "grant-1",
        "--approve",
        "--actor",
        "lead",
        "--json",
    ])
    .expect("parse policy grant resolve");
    match task_board_command(resolve.command) {
        TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::GrantResolve(args),
        } => {
            assert_eq!(args.grant_id, "grant-1");
            assert!(args.approve);
            assert!(!args.deny);
            assert_eq!(args.actor.as_deref(), Some("lead"));
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Policy GrantResolve"),
    }
}

#[test]
fn parse_policy_grant_revoke() {
    let revoke = Cli::try_parse_from([
        "harness",
        "task-board",
        "policy",
        "grant-revoke",
        "grant-1",
        "--actor",
        "lead",
        "--json",
    ])
    .expect("parse policy grant revoke");
    match task_board_command(revoke.command) {
        TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::GrantRevoke(args),
        } => {
            assert_eq!(args.grant_id, "grant-1");
            assert_eq!(args.actor.as_deref(), Some("lead"));
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Policy GrantRevoke"),
    }
}

#[test]
fn parse_policy_spawn_requires_live_policy() {
    let cli = Cli::try_parse_from([
        "harness",
        "task-board",
        "policy",
        "spawn-requires-live-policy",
        "--enabled",
        "true",
        "--json",
    ])
    .expect("parse spawn requires live policy");
    match task_board_command(cli.command) {
        TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::SpawnRequiresLivePolicy(args),
        } => {
            assert!(args.enabled);
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Policy SpawnRequiresLivePolicy"),
    }
}

#[test]
fn parse_policy_spawn_kill_switch() {
    let cli = Cli::try_parse_from([
        "harness",
        "task-board",
        "policy",
        "spawn-kill-switch",
        "--enabled",
        "false",
        "--json",
    ])
    .expect("parse spawn kill switch");
    match task_board_command(cli.command) {
        TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::SpawnKillSwitch(args),
        } => {
            assert!(!args.enabled);
            assert!(args.json);
        }
        _ => panic!("expected TaskBoard Policy SpawnKillSwitch"),
    }
}

#[test]
fn task_board_grant_resolution_requires_one_decision() {
    let missing = Cli::try_parse_from([
        "harness",
        "task-board",
        "policy",
        "grant-resolve",
        "grant-1",
    ])
    .expect_err("grant resolution needs approve or deny");
    assert_eq!(missing.kind(), ErrorKind::MissingRequiredArgument);

    let conflicting = Cli::try_parse_from([
        "harness",
        "task-board",
        "policy",
        "grant-resolve",
        "grant-1",
        "--approve",
        "--deny",
    ])
    .expect_err("grant resolution decisions conflict");
    assert_eq!(conflicting.kind(), ErrorKind::ArgumentConflict);
}
