use super::*;

#[test]
fn parse_create_begin() {
    let cli = Cli::try_parse_from([
        "harness",
        "create",
        "begin",
        "--repo-root",
        "/repo",
        "--feature",
        "mesh-traffic",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
        "--suite-name",
        "mesh-suite",
    ])
    .unwrap();
    match cli.command {
        Command::Create {
            command: CreateCommand::Begin(CreateBeginArgs { feature, mode, .. }),
        } => {
            assert_eq!(feature, "mesh-traffic");
            assert_eq!(mode, "interactive");
        }
        _ => panic!("expected CreateBegin command"),
    }
}

#[test]
fn create_begin_rejects_legacy_skill_flag() {
    let result = Cli::try_parse_from([
        "harness",
        "create",
        "begin",
        "--skill",
        "suite:create",
        "--repo-root",
        "/repo",
        "--feature",
        "mesh-traffic",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
        "--suite-name",
        "mesh-suite",
    ]);

    assert!(result.is_err(), "legacy --skill flag should be rejected");
}

#[test]
fn parse_create_approval_begin() {
    let cli = Cli::try_parse_from([
        "harness",
        "create",
        "approval-begin",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
    ])
    .unwrap();

    match cli.command {
        Command::Create {
            command: CreateCommand::ApprovalBegin(ApprovalBeginArgs { mode, suite_dir }),
        } => {
            assert_eq!(mode, "interactive");
            assert_eq!(suite_dir.as_deref(), Some("/suites/mesh"));
        }
        _ => panic!("expected Create ApprovalBegin command"),
    }
}

#[test]
fn create_approval_begin_rejects_legacy_skill_flag() {
    let result = Cli::try_parse_from([
        "harness",
        "create",
        "approval-begin",
        "--skill",
        "suite:create",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
    ]);

    assert!(result.is_err(), "legacy --skill flag should be rejected");
}

#[test]
fn parse_create_reset() {
    let cli = Cli::try_parse_from(["harness", "create", "reset"]).unwrap();

    assert!(matches!(
        cli.command,
        Command::Create {
            command: CreateCommand::Reset(CreateResetArgs),
        }
    ));
}

#[test]
fn create_reset_rejects_legacy_skill_flag() {
    let result = Cli::try_parse_from(["harness", "create", "reset", "--skill", "suite:create"]);

    assert!(result.is_err(), "legacy --skill flag should be rejected");
}
