//! Parse tests for the non-review `session task` subcommands: create, assign,
//! list, and update. The update variant covers the status-enum alias surface
//! (snake_case plus legacy kebab-case) and the new `awaiting_review` slot.
//!
//! The review-workflow task subcommands (submit-for-review, claim-review,
//! submit-review, respond-review, arbitrate) live in
//! [`session_review`](super::session_review).

use super::*;

#[test]
fn parse_session_task_create() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "create",
        "sess-abc",
        "--title",
        "fix bug",
        "--severity",
        "high",
        "--actor",
        "leader-1",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command:
                crate::session::transport::SessionCommand::Task {
                    command: crate::session::transport::SessionTaskCommand::Create(args),
                },
        } => {
            assert_eq!(args.session_id, "sess-abc");
            assert_eq!(args.title, "fix bug");
            assert_eq!(args.severity, crate::session::types::TaskSeverity::High);
        }
        _ => panic!("expected Session Task Create"),
    }
}

#[test]
fn parse_session_task_assign() {
    let cli = Cli::try_parse_from([
        "harness", "session", "task", "assign", "sess-ta", "task-1", "agent-1", "--actor",
        "leader-1",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Assign(args),
            },
    } = cli.command
    else {
        panic!("expected Session Task Assign");
    };
    assert_eq!(args.task_id, "task-1");
    assert_eq!(args.agent_id, "agent-1");
}

#[test]
fn parse_session_task_list() {
    let cli = Cli::try_parse_from([
        "harness", "session", "task", "list", "sess-tl", "--status", "open", "--json",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::List(args),
            },
    } = cli.command
    else {
        panic!("expected Session Task List");
    };
    assert_eq!(args.status, Some(crate::session::types::TaskStatus::Open));
    assert!(args.json);
}

#[test]
fn parse_session_task_update() {
    let cli = Cli::try_parse_from([
        "harness", "session", "task", "update", "sess-tu", "task-1", "--status", "done", "--note",
        "fixed it", "--actor", "worker-1",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Update(args),
            },
    } = cli.command
    else {
        panic!("expected Session Task Update");
    };
    assert_eq!(args.status, crate::session::types::TaskStatus::Done);
    assert_eq!(args.note, Some("fixed it".into()));
}

#[test]
fn parse_session_task_update_accepts_snake_case_in_progress() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "update",
        "sess",
        "task-1",
        "--status",
        "in_progress",
        "--actor",
        "worker-1",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Update(args),
            },
    } = cli.command
    else {
        panic!("expected task update");
    };
    assert_eq!(args.status, crate::session::types::TaskStatus::InProgress);
}

#[test]
fn parse_session_task_update_accepts_kebab_in_progress_alias() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "update",
        "sess",
        "task-1",
        "--status",
        "in-progress",
        "--actor",
        "worker-1",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Update(args),
            },
    } = cli.command
    else {
        panic!("expected task update");
    };
    assert_eq!(args.status, crate::session::types::TaskStatus::InProgress);
}

#[test]
fn parse_session_task_update_accepts_awaiting_review_status() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "update",
        "sess",
        "task-1",
        "--status",
        "awaiting_review",
        "--actor",
        "worker-1",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Update(args),
            },
    } = cli.command
    else {
        panic!("expected task update");
    };
    assert_eq!(
        args.status,
        crate::session::types::TaskStatus::AwaitingReview
    );
}
