//! Parse tests for session lifecycle commands: start, end, assign (role),
//! remove, transfer-leader, recover-leader, observe, status, list, and the
//! removed-tui guard.
//!
//! Join and managed-agent start live in [`session_join`], task mutation lives
//! in [`session_task`], review-workflow lives in [`session_review`], and
//! improver-apply lives in [`session_improver`].

use super::*;

#[test]
fn parse_session_observe_with_actor() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "observe",
        "sess-1",
        "--poll-interval",
        "5",
        "--json",
        "--actor",
        "claude-leader",
        "--project-dir",
        "/tmp/project",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command:
                SessionCommand::Observe(SessionObserveArgs {
                    session_id,
                    poll_interval,
                    json,
                    actor,
                    project_dir,
                }),
        } => {
            assert_eq!(session_id, "sess-1");
            assert_eq!(poll_interval, 5);
            assert!(json);
            assert_eq!(actor.as_deref(), Some("claude-leader"));
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected Session observe command"),
    }
}

#[test]
fn parse_session_start() {
    let cli =
        Cli::try_parse_from(["harness", "session", "start", "--context", "test goal"]).unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Start(args),
        } => {
            assert_eq!(args.context, "test goal");
        }
        _ => panic!("expected Session Start"),
    }
}

#[test]
fn parse_session_start_with_policy_preset() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "start",
        "--context",
        "test goal",
        "--policy-preset",
        "swarm-default",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Start(args),
        } => {
            assert_eq!(args.context, "test goal");
            assert_eq!(args.policy_preset.as_deref(), Some("swarm-default"));
        }
        _ => panic!("expected Session Start"),
    }
}

#[test]
fn parse_session_end() {
    let cli = Cli::try_parse_from(["harness", "session", "end", "sess-x", "--actor", "leader-1"])
        .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::End(args),
    } = cli.command
    else {
        panic!("expected Session End");
    };
    assert_eq!(args.session_id, "sess-x");
    assert_eq!(args.actor, "leader-1");
}

#[test]
fn parse_session_assign() {
    let cli = Cli::try_parse_from([
        "harness", "session", "assign", "sess-a", "agent-1", "--role", "reviewer", "--actor",
        "leader-1",
    ])
    .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::Assign(args),
    } = cli.command
    else {
        panic!("expected Session Assign");
    };
    assert_eq!(args.agent_id, "agent-1");
    assert_eq!(args.role, crate::session::types::SessionRole::Reviewer);
}

#[test]
fn parse_session_remove() {
    let cli = Cli::try_parse_from([
        "harness", "session", "remove", "sess-r", "agent-2", "--actor", "leader-1",
    ])
    .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::Remove(args),
    } = cli.command
    else {
        panic!("expected Session Remove");
    };
    assert_eq!(args.agent_id, "agent-2");
}

#[test]
fn parse_session_transfer_leader() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "transfer-leader",
        "sess-t",
        "new-leader",
        "--reason",
        "529 errors",
        "--actor",
        "obs-1",
    ])
    .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::TransferLeader(args),
    } = cli.command
    else {
        panic!("expected Session TransferLeader");
    };
    assert_eq!(args.new_leader_id, "new-leader");
    assert_eq!(args.reason, Some("529 errors".into()));
}

#[test]
fn parse_session_recover_leader() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "recover-leader",
        "sess-r",
        "--preset",
        "swarm-default",
        "--runtime",
        "codex",
        "--project-dir",
        "/tmp/project",
    ])
    .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::RecoverLeader(args),
    } = cli.command
    else {
        panic!("expected Session RecoverLeader");
    };
    assert_eq!(args.session_id, "sess-r");
    assert_eq!(args.preset, "swarm-default");
    assert_eq!(args.runtime, crate::hooks::adapters::HookAgent::Codex);
    assert_eq!(args.project_dir.as_deref(), Some("/tmp/project"));
}

#[test]
fn parse_session_status() {
    let cli = Cli::try_parse_from(["harness", "session", "status", "sess-s", "--json"]).unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::Status(args),
    } = cli.command
    else {
        panic!("expected Session Status");
    };
    assert_eq!(args.session_id, "sess-s");
    assert!(args.json);
}

#[test]
fn parse_session_list() {
    let cli = Cli::try_parse_from(["harness", "session", "list", "--json"]).unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::List(args),
    } = cli.command
    else {
        panic!("expected Session List");
    };
    assert!(args.json);
}

#[test]
fn parse_session_tui_is_removed() {
    assert!(Cli::try_parse_from(["harness", "session", "tui", "list", "sess-1"]).is_err());
}
