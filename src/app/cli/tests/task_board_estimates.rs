use clap::Parser;

use super::{Cli, TaskBoardCommand, task_board_command};

const MAX_ESTIMATE: &str = "9223372036854775807";

#[test]
fn task_board_estimates_accept_the_persisted_integer_range() {
    let cli = Cli::try_parse_from([
        "harness",
        "task-board",
        "create",
        "--title",
        "Bounded task",
        "--estimated-tokens",
        "1",
        "--estimated-cost-microusd",
        MAX_ESTIMATE,
    ])
    .expect("parse bounded estimates");

    match task_board_command(cli.command) {
        TaskBoardCommand::Create(args) => {
            assert_eq!(args.fields.estimated_tokens, Some(1));
            assert_eq!(args.fields.estimated_cost_microusd, Some(i64::MAX as u64));
        }
        _ => panic!("expected Task Board Create"),
    }
}

#[test]
fn task_board_estimates_reject_values_outside_the_persisted_range() {
    for value in ["0", "9223372036854775808", "-1", "1.5"] {
        assert!(
            Cli::try_parse_from([
                "harness",
                "task-board",
                "create",
                "--title",
                "Invalid task",
                "--estimated-tokens",
                value,
            ])
            .is_err(),
            "estimate {value} must be rejected"
        );
    }
}

#[test]
fn task_board_update_rejects_setting_and_clearing_the_same_estimate() {
    assert!(
        Cli::try_parse_from([
            "harness",
            "task-board",
            "update",
            "task-1",
            "--estimated-tokens",
            "1",
            "--clear-estimated-tokens",
        ])
        .is_err()
    );
    assert!(
        Cli::try_parse_from([
            "harness",
            "task-board",
            "update",
            "task-1",
            "--estimated-cost-microusd",
            "1",
            "--clear-estimated-cost-microusd",
        ])
        .is_err()
    );
}
