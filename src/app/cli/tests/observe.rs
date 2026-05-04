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
fn top_level_lifecycle_commands_accept_project_dir() {
    fn extract(cmd: Command) -> Option<String> {
        match cmd {
            Command::SessionStart(SessionStartArgs { project_dir }) => project_dir,
            Command::SessionStop(SessionStopArgs { project_dir }) => project_dir,
            Command::PreCompact(PreCompactArgs { project_dir }) => project_dir,
            _ => panic!("expected lifecycle command"),
        }
    }
    for subcmd in ["session-start", "session-stop", "pre-compact"] {
        let cli =
            Cli::try_parse_from(["harness", subcmd, "--project-dir", "/tmp/project"]).unwrap();
        let project_dir = extract(cli.command);
        assert_eq!(
            project_dir.as_deref(),
            Some("/tmp/project"),
            "subcmd: {subcmd}"
        );
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
