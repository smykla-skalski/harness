// Tests for the session stop command.

use harness::setup::SessionStopArgs;

use super::super::helpers::*;

#[test]
fn session_stop_succeeds() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("session-stop-test")),
        ],
        || {
            let code =
                run_command(session_stop_cmd(SessionStopArgs { project_dir: None })).unwrap();
            assert_eq!(code, 0);
        },
    );
}
