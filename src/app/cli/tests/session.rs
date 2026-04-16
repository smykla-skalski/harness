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
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "start",
        "--context",
        "test goal",
        "--runtime",
        "claude",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Start(args),
        } => {
            assert_eq!(args.context, "test goal");
            assert_eq!(
                args.runtime,
                Some(crate::hooks::adapters::HookAgent::Claude)
            );
        }
        _ => panic!("expected Session Start"),
    }
}

#[test]
fn parse_session_join() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "join",
        "sess-123",
        "--role",
        "worker",
        "--runtime",
        "codex",
        "--capabilities",
        "general,testing",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Join(args),
        } => {
            assert_eq!(args.session_id, "sess-123");
            assert_eq!(args.role, crate::session::types::SessionRole::Worker);
            assert_eq!(args.capabilities, Some("general,testing".into()));
        }
        _ => panic!("expected Session Join"),
    }
}

#[test]
fn parse_session_join_with_fallback_role() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "join",
        "sess-123",
        "--role",
        "leader",
        "--fallback-role",
        "improver",
        "--runtime",
        "codex",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Join(args),
        } => {
            assert_eq!(args.session_id, "sess-123");
            assert_eq!(args.role, crate::session::types::SessionRole::Leader);
            assert_eq!(
                args.fallback_role,
                Some(crate::session::types::SessionRole::Improver)
            );
        }
        _ => panic!("expected Session Join"),
    }
}

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
