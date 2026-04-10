use std::fs;
use std::path::PathBuf;

use harness::app::cli::Command;
use harness::daemon::transport::{
    DaemonCommand, DaemonInstallLaunchAgentArgs, DaemonRemoveLaunchAgentArgs,
};
use tempfile::tempdir;

use super::helpers::run_command;

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
            let command = Command::Daemon {
                command: DaemonCommand::InstallLaunchAgent(DaemonInstallLaunchAgentArgs {
                    binary_path: Some(PathBuf::from(&binary)),
                    json: false,
                }),
            };
            let error = run_command(command).expect_err("install must refuse in sandbox mode");
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
            let command = Command::Daemon {
                command: DaemonCommand::RemoveLaunchAgent(DaemonRemoveLaunchAgentArgs {
                    json: false,
                }),
            };
            let error = run_command(command).expect_err("remove must refuse in sandbox mode");
            assert_eq!(error.code(), "SANDBOX001");
            assert!(error.to_string().contains("launch-agent-remove"));
        },
    );
}
