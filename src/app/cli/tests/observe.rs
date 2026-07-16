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
fn removed_top_level_lifecycle_commands_are_rejected() {
    for subcmd in ["session-start", "session-stop", "pre-compact"] {
        let error = Cli::try_parse_from(["harness", subcmd, "--project-dir", "/tmp/project"])
            .expect_err("legacy lifecycle route must be a hard cut");
        assert_eq!(error.kind(), ErrorKind::InvalidSubcommand, "{subcmd}");
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
