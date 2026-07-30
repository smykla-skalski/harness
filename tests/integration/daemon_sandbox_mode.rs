use std::fs;
use std::path::PathBuf;

use harness_daemon::app::{AppContext, Execute};
// `DaemonCommand` moved into its own crate (#1230). It compiles natively
// against `harness-daemon`'s own `#[path]`-duplicated `command_context.rs`
// for its nominal `AppContext`/`Execute` identity (see
// `crates/harness-daemon/src/app.rs`), distinct from
// `harness_workspace::command_context`'s own copy; this import has to match
// the one `harness-daemon-cli`'s own `commands` module actually implements
// `Execute` against, or `DaemonCommand::execute` fails to resolve.
use harness_daemon_cli::{
    DaemonCommand, DaemonInstallLaunchAgentArgs, DaemonRemoveLaunchAgentArgs,
};
use tempfile::tempdir;

#[test]
fn install_launch_agent_refuses_when_sandbox_env_is_set() {
    let tmp = tempdir().expect("tempdir");
    let binary = tmp.path().join("harness-fake");
    fs::write(&binary, b"").expect("write fake binary");

    temp_env::with_vars(
        [
            ("HARNESS_SANDBOXED", Some("1")),
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
        ],
        || {
            let command = DaemonCommand::InstallLaunchAgent(DaemonInstallLaunchAgentArgs {
                binary_path: Some(PathBuf::from(&binary)),
                json: false,
            });
            let error = command
                .execute(&AppContext::production())
                .expect_err("install must refuse in sandbox mode");
            assert_eq!(error.code(), "SANDBOX001");
            assert!(error.to_string().contains("launch-agent-install"));
        },
    );
}

#[test]
fn remove_launch_agent_refuses_when_sandbox_env_is_set() {
    let tmp = tempdir().expect("tempdir");

    temp_env::with_vars(
        [
            ("HARNESS_SANDBOXED", Some("true")),
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
        ],
        || {
            let command =
                DaemonCommand::RemoveLaunchAgent(DaemonRemoveLaunchAgentArgs { json: false });
            let error = command
                .execute(&AppContext::production())
                .expect_err("remove must refuse in sandbox mode");
            assert_eq!(error.code(), "SANDBOX001");
            assert!(error.to_string().contains("launch-agent-remove"));
        },
    );
}
