//! Parse tests for the multi-agent review-workflow task subcommands:
//! `submit-for-review`, `claim-review`, `submit-review`, `respond-review`,
//! and `arbitrate`. These cover the `ReviewVerdict` enum's snake_case /
//! kebab-case alias surface and the CSV splitter on
//! `respond-review --agreed/--disputed`.

use super::*;

#[test]
fn parse_session_task_submit_for_review() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "submit-for-review",
        "sess-rv",
        "task-9",
        "--actor",
        "worker-1",
        "--summary",
        "ready",
        "--suggested-persona",
        "code-reviewer",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::SubmitForReview(args),
            },
    } = cli.command
    else {
        panic!("expected SubmitForReview");
    };
    assert_eq!(args.session_id, "sess-rv");
    assert_eq!(args.task_id, "task-9");
    assert_eq!(args.actor, "worker-1");
    assert_eq!(args.summary.as_deref(), Some("ready"));
    assert_eq!(args.suggested_persona.as_deref(), Some("code-reviewer"));
}

#[test]
fn parse_session_task_claim_review() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "claim-review",
        "sess-rv",
        "task-9",
        "--actor",
        "reviewer-gemini",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::ClaimReview(args),
            },
    } = cli.command
    else {
        panic!("expected ClaimReview");
    };
    assert_eq!(args.task_id, "task-9");
    assert_eq!(args.actor, "reviewer-gemini");
}

#[test]
fn parse_session_task_submit_review_with_snake_case_verdict() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "submit-review",
        "sess-rv",
        "task-9",
        "--actor",
        "reviewer-1",
        "--verdict",
        "request_changes",
        "--summary",
        "needs work",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::SubmitReview(args),
            },
    } = cli.command
    else {
        panic!("expected SubmitReview");
    };
    assert_eq!(
        args.verdict,
        crate::session::types::ReviewVerdict::RequestChanges
    );
    assert_eq!(args.summary, "needs work");
    assert!(args.points.is_none());
}

#[test]
fn parse_session_task_submit_review_accepts_kebab_verdict_alias() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "submit-review",
        "sess-rv",
        "task-9",
        "--actor",
        "reviewer-1",
        "--verdict",
        "request-changes",
        "--summary",
        "needs work",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::SubmitReview(args),
            },
    } = cli.command
    else {
        panic!("expected SubmitReview");
    };
    assert_eq!(
        args.verdict,
        crate::session::types::ReviewVerdict::RequestChanges
    );
}

#[test]
fn parse_session_task_submit_review_accepts_reject_verdict() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "submit-review",
        "sess-rv",
        "task-9",
        "--actor",
        "reviewer-1",
        "--verdict",
        "reject",
        "--summary",
        "not shipping",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::SubmitReview(args),
            },
    } = cli.command
    else {
        panic!("expected SubmitReview");
    };
    assert_eq!(args.verdict, crate::session::types::ReviewVerdict::Reject);
}

#[test]
fn parse_session_task_submit_review_with_points_json() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "submit-review",
        "sess-rv",
        "task-9",
        "--actor",
        "reviewer-1",
        "--verdict",
        "approve",
        "--summary",
        "lgtm",
        "--points",
        r#"[{"point_id":"p1","text":"first","state":"agreed"}]"#,
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::SubmitReview(args),
            },
    } = cli.command
    else {
        panic!("expected SubmitReview");
    };
    assert_eq!(args.verdict, crate::session::types::ReviewVerdict::Approve);
    assert!(args.points.as_deref().unwrap().contains(r#""point_id":"p1""#));
}

#[test]
fn parse_session_task_respond_review_splits_csv_points() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "respond-review",
        "sess-rv",
        "task-9",
        "--actor",
        "worker-1",
        "--agreed",
        "p1,p2",
        "--disputed",
        "p3",
        "--note",
        "redoing p3",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::RespondReview(args),
            },
    } = cli.command
    else {
        panic!("expected RespondReview");
    };
    assert_eq!(args.agreed, vec!["p1".to_string(), "p2".to_string()]);
    assert_eq!(args.disputed, vec!["p3".to_string()]);
    assert_eq!(args.note.as_deref(), Some("redoing p3"));
}

#[test]
fn parse_session_task_arbitrate() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "arbitrate",
        "sess-rv",
        "task-9",
        "--actor",
        "leader-1",
        "--verdict",
        "approve",
        "--summary",
        "shipping",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Arbitrate(args),
            },
    } = cli.command
    else {
        panic!("expected Arbitrate");
    };
    assert_eq!(args.verdict, crate::session::types::ReviewVerdict::Approve);
    assert_eq!(args.summary, "shipping");
}
