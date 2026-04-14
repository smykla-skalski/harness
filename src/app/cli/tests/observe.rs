use super::*;

#[test]
fn parse_observe_doctor() {
    let cli = Cli::try_parse_from([
        "harness",
        "observe",
        "doctor",
        "--json",
        "--project-dir",
        "/tmp/project",
    ])
    .unwrap();
    match cli.command {
        Command::Observe(args) => {
            let ObserveArgs {
                agent,
                observe_id,
                mode: ObserveMode::Doctor { json, project_dir },
            } = *args
            else {
                panic!("expected Doctor mode");
            };
            assert!(agent.is_none());
            assert_eq!(observe_id, "project-default");
            assert!(json);
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected Observe Doctor command"),
    }
}

#[test]
fn parse_observe_scope_flags() {
    let cli = Cli::try_parse_from([
        "harness",
        "observe",
        "--agent",
        "codex",
        "--observe-id",
        "shared-ledger",
        "doctor",
        "--json",
    ])
    .unwrap();
    match cli.command {
        Command::Observe(args) => {
            let ObserveArgs {
                agent,
                observe_id,
                mode: ObserveMode::Doctor { json, project_dir },
            } = *args
            else {
                panic!("expected Doctor mode");
            };
            assert_eq!(agent, Some(HookAgent::Codex));
            assert_eq!(observe_id, "shared-ledger");
            assert!(json);
            assert!(project_dir.is_none());
        }
        _ => panic!("expected Observe Doctor command with scope flags"),
    }
}

#[test]
fn reject_legacy_observe_scan_doctor_action() {
    let error = Cli::try_parse_from(["harness", "observe", "scan", "--action", "doctor"])
        .expect_err("legacy doctor action should fail");
    assert_eq!(error.kind(), ErrorKind::InvalidValue);
}

#[test]
fn parse_top_level_session_start() {
    let cli =
        Cli::try_parse_from(["harness", "session-start", "--project-dir", "/tmp/project"]).unwrap();
    match cli.command {
        Command::SessionStart(SessionStartArgs { project_dir }) => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected top-level SessionStart command"),
    }
}

#[test]
fn parse_top_level_session_stop() {
    let cli =
        Cli::try_parse_from(["harness", "session-stop", "--project-dir", "/tmp/project"]).unwrap();
    match cli.command {
        Command::SessionStop(SessionStopArgs { project_dir }) => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected top-level SessionStop command"),
    }
}

#[test]
fn parse_top_level_pre_compact() {
    let cli =
        Cli::try_parse_from(["harness", "pre-compact", "--project-dir", "/tmp/project"]).unwrap();
    match cli.command {
        Command::PreCompact(PreCompactArgs { project_dir }) => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected top-level PreCompact command"),
    }
}

#[test]
fn reject_grouped_lifecycle_commands_under_setup() {
    for argv in [
        vec![
            "harness",
            "setup",
            "session-start",
            "--project-dir",
            "/tmp/project",
        ],
        vec![
            "harness",
            "setup",
            "session-stop",
            "--project-dir",
            "/tmp/project",
        ],
        vec![
            "harness",
            "setup",
            "pre-compact",
            "--project-dir",
            "/tmp/project",
        ],
    ] {
        let error = Cli::try_parse_from(argv).expect_err("grouped lifecycle form should fail");
        assert_eq!(error.kind(), ErrorKind::InvalidSubcommand);
    }
}
