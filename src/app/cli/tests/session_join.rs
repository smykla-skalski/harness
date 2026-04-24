//! Parse tests for commands that admit agents into a session: `session join`
//! and the managed-terminal / managed-codex launchers under `session agents
//! start`. Grouped together because all three shape the initial membership
//! of a session.

use super::*;

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
fn parse_session_agents_start_terminal() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "agents",
        "start",
        "terminal",
        "sess-terminal",
        "--runtime",
        "codex",
        "--role",
        "worker",
        "--fallback-role",
        "reviewer",
        "--capability",
        "debug",
        "--capability",
        "tests",
        "--name",
        "Terminal Worker",
        "--prompt",
        "Inspect the failure",
        "--project-dir",
        "/tmp/project",
        "--arg",
        "codex",
        "--arg",
        "--model",
        "--arg",
        "gpt-5.4",
        "--rows",
        "40",
        "--cols",
        "140",
        "--persona",
        "reviewer",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Agents {
                command:
                    crate::session::transport::SessionAgentsCommand::Start {
                        command: crate::session::transport::SessionAgentStartCommand::Terminal(args),
                    },
            },
    } = cli.command
    else {
        panic!("expected Session Agents Start Terminal");
    };
    assert_eq!(args.session_id, "sess-terminal");
    assert_eq!(args.runtime, crate::hooks::adapters::HookAgent::Codex);
    assert_eq!(args.role, crate::session::types::SessionRole::Worker);
    assert_eq!(
        args.fallback_role,
        Some(crate::session::types::SessionRole::Reviewer)
    );
    assert_eq!(
        args.capabilities,
        vec!["debug".to_string(), "tests".to_string()]
    );
    assert_eq!(args.name.as_deref(), Some("Terminal Worker"));
    assert_eq!(args.prompt.as_deref(), Some("Inspect the failure"));
    assert_eq!(args.project_dir.as_deref(), Some("/tmp/project"));
    assert_eq!(
        args.argv,
        vec![
            "codex".to_string(),
            "--model".to_string(),
            "gpt-5.4".to_string()
        ]
    );
    assert_eq!(args.rows, 40);
    assert_eq!(args.cols, 140);
    assert_eq!(args.persona.as_deref(), Some("reviewer"));
}

#[test]
fn parse_session_agents_start_codex() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "agents",
        "start",
        "codex",
        "sess-codex",
        "--prompt",
        "Patch the bridge flow",
        "--mode",
        "approval",
        "--resume-thread-id",
        "thread-123",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Agents {
                command:
                    crate::session::transport::SessionAgentsCommand::Start {
                        command: crate::session::transport::SessionAgentStartCommand::Codex(args),
                    },
            },
    } = cli.command
    else {
        panic!("expected Session Agents Start Codex");
    };
    assert_eq!(args.session_id, "sess-codex");
    assert_eq!(args.prompt, "Patch the bridge flow");
    assert_eq!(args.mode, crate::daemon::protocol::CodexRunMode::Approval);
    assert_eq!(args.resume_thread_id.as_deref(), Some("thread-123"));
}
