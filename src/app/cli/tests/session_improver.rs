//! Parse tests for `session improver apply`. Covers target-enum snake_case
//! spelling and the default `--dry-run=false` path.

use super::*;

#[test]
fn parse_session_improver_apply() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "improver",
        "apply",
        "sess-imp",
        "--actor",
        "improver-1",
        "--issue-id",
        "python_traceback_output/abc",
        "--target",
        "skill",
        "--rel-path",
        "observe/SKILL.md",
        "--new-contents-file",
        "/tmp/new.md",
        "--dry-run",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Improver {
                command: crate::session::transport::SessionImproverCommand::Apply(args),
            },
    } = cli.command
    else {
        panic!("expected Improver Apply");
    };
    assert_eq!(args.session_id, "sess-imp");
    assert_eq!(args.issue_id, "python_traceback_output/abc");
    assert_eq!(args.target, crate::session::service::ImproverTarget::Skill);
    assert_eq!(args.rel_path, "observe/SKILL.md");
    assert_eq!(args.new_contents_file, "/tmp/new.md");
    assert!(args.dry_run);
}

#[test]
fn parse_session_improver_apply_target_local_skill_claude() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "improver",
        "apply",
        "sess-imp",
        "--actor",
        "improver-1",
        "--issue-id",
        "x/y",
        "--target",
        "local_skill_claude",
        "--rel-path",
        "foo/bar.md",
        "--new-contents-file",
        "/tmp/c.md",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Improver {
                command: crate::session::transport::SessionImproverCommand::Apply(args),
            },
    } = cli.command
    else {
        panic!("expected Improver Apply");
    };
    assert_eq!(
        args.target,
        crate::session::service::ImproverTarget::LocalSkillClaude
    );
    assert!(!args.dry_run);
}
