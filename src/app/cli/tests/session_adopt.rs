use std::path::PathBuf;

use super::*;

#[test]
fn parse_session_adopt_minimal() {
    let cli = Cli::try_parse_from(["harness", "session", "adopt", "/tmp/sessions/kuma/abc12345"])
        .expect("parse");
    match cli.command {
        Command::Session { command } => match command {
            crate::session::transport::SessionCommand::Adopt(args) => {
                assert_eq!(args.path, PathBuf::from("/tmp/sessions/kuma/abc12345"));
                assert!(args.bookmark_id.is_none());
            }
            other => panic!("unexpected {other:?}"),
        },
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn parse_session_adopt_with_bookmark() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "adopt",
        "/tmp/s",
        "--bookmark-id",
        "B-abc",
    ])
    .expect("parse");
    match cli.command {
        Command::Session { command } => match command {
            crate::session::transport::SessionCommand::Adopt(args) => {
                assert_eq!(args.bookmark_id.as_deref(), Some("B-abc"));
                assert_eq!(args.path, PathBuf::from("/tmp/s"));
            }
            other => panic!("unexpected {other:?}"),
        },
        other => panic!("unexpected {other:?}"),
    }
}
