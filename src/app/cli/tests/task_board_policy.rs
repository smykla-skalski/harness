use clap::{Parser, error::ErrorKind};

use super::{Cli, task_board_command};
use crate::task_board::transport::{TaskBoardCommand, TaskBoardPolicyCommand};

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
fn parse_task_board_spawn_policy_controls() {
    let grants = Cli::try_parse_from(["harness", "task-board", "policy", "grants", "--json"])
        .expect("parse policy grants");
    match task_board_command(grants.command) {
        TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::Grants(args),
        } => assert!(args.json),
        _ => panic!("expected TaskBoard Policy Grants"),
    }

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

    for (name, enabled) in [
        ("spawn-requires-live-policy", true),
        ("spawn-kill-switch", false),
    ] {
        let cli = Cli::try_parse_from([
            "harness",
            "task-board",
            "policy",
            name,
            "--enabled",
            if enabled { "true" } else { "false" },
            "--json",
        ])
        .expect("parse policy toggle");
        match (task_board_command(cli.command), name) {
            (
                TaskBoardCommand::Policy {
                    command: TaskBoardPolicyCommand::SpawnRequiresLivePolicy(args),
                },
                "spawn-requires-live-policy",
            ) => {
                assert!(args.enabled);
                assert!(args.json);
            }
            (
                TaskBoardCommand::Policy {
                    command: TaskBoardPolicyCommand::SpawnKillSwitch(args),
                },
                "spawn-kill-switch",
            ) => {
                assert!(!args.enabled);
                assert!(args.json);
            }
            _ => panic!("expected TaskBoard Policy toggle"),
        }
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
