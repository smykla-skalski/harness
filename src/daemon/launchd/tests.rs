use std::path::Path;
use std::sync::{Arc, Mutex};

use fs_err as fs;
use tempfile::tempdir;

use super::operations::{
    best_effort_bootout, install_launch_agent_with, remove_launch_agent_with,
    restart_launch_agent_with,
};
use super::status::{LaunchctlPrintStatus, launch_agent_status_with, parse_launchctl_print};
use super::support::{
    CommandOutput, launchd_domain_target, launchd_service_target, launchd_service_target_for,
};
use super::*;

#[test]
fn render_launch_agent_plist_contains_expected_fields() {
    let plist = render_launch_agent_plist(Path::new("/usr/local/bin/harness"));
    assert!(plist.contains(LAUNCH_AGENT_LABEL));
    assert!(plist.contains("<string>daemon</string>"));
    assert!(plist.contains("<string>serve</string>"));
}

#[test]
fn launch_agent_install_and_remove_round_trip() {
    let tmp = tempdir().expect("tempdir");
    let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
    let runner = {
        let calls = Arc::clone(&calls);
        move |args: &[String]| -> Result<CommandOutput, CliError> {
            calls.lock().expect("lock").push(args.to_vec());
            let output = if args.first().is_some_and(|value| value == "print") {
                CommandOutput {
                    exit_code: 1,
                    stdout: String::new(),
                    stderr: "Could not find service".to_string(),
                }
            } else {
                CommandOutput {
                    exit_code: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                }
            };
            Ok(output)
        }
    };
    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path"))),
        ],
        || {
            let path = install_launch_agent_with(Path::new("/tmp/harness-bin"), &runner)
                .expect("install launch agent");
            assert_eq!(path, state::launch_agent_path());
            assert!(path.is_file());

            let status = launch_agent_status_with(&|args| {
                if args.first().is_some_and(|value| value == "print") {
                    return Ok(CommandOutput {
                        exit_code: 0,
                        stdout: format!(
                            r#"{service} = {{
    state = running
    pid = 4242
    last exit code = 0
}}"#,
                            service = launchd_service_target()
                        ),
                        stderr: String::new(),
                    });
                }
                runner(args)
            });
            assert!(status.installed);
            assert!(status.loaded);
            assert_eq!(status.label, LAUNCH_AGENT_LABEL);
            assert_eq!(status.state.as_deref(), Some("running"));
            assert_eq!(status.pid, Some(4242));
            assert_eq!(status.last_exit_status, Some(0));

            let plist = fs::read_to_string(&path).expect("read plist");
            assert!(plist.contains("/tmp/harness-bin"));
            assert!(plist.contains("daemon"));
            assert!(plist.contains("serve"));

            assert!(remove_launch_agent_with(&runner).expect("remove launch agent"));
            assert!(!path.exists());
            assert!(
                calls
                    .lock()
                    .expect("lock")
                    .iter()
                    .any(|args| { args.first().is_some_and(|value| value == "bootstrap") })
            );
            assert!(
                calls
                    .lock()
                    .expect("lock")
                    .iter()
                    .any(|args| { args.first().is_some_and(|value| value == "kickstart") })
            );
        },
    );
}

#[test]
fn install_launch_agent_removes_legacy_plist() {
    let tmp = tempdir().expect("tempdir");
    let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
    let runner = {
        let calls = Arc::clone(&calls);
        move |args: &[String]| -> Result<CommandOutput, CliError> {
            calls.lock().expect("lock").push(args.to_vec());
            Ok(CommandOutput {
                exit_code: 0,
                stdout: String::new(),
                stderr: String::new(),
            })
        }
    };
    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path"))),
        ],
        || {
            let legacy_path = state::legacy_launch_agent_path();
            fs::create_dir_all(legacy_path.parent().expect("legacy parent"))
                .expect("create legacy launch agent dir");
            fs::write(&legacy_path, "legacy plist").expect("write legacy plist");

            let path = install_launch_agent_with(Path::new("/tmp/harness-bin"), &runner)
                .expect("install launch agent");

            assert!(path.is_file());
            assert!(!legacy_path.exists());
            assert!(calls.lock().expect("lock").iter().any(|args| {
                args == &vec![
                    "bootout".to_string(),
                    launchd_service_target_for(LEGACY_LAUNCH_AGENT_LABEL),
                ]
            }));
        },
    );
}

#[test]
fn restart_launch_agent_uses_existing_plist() {
    let tmp = tempdir().expect("tempdir");
    let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
    let runner = {
        let calls = Arc::clone(&calls);
        move |args: &[String]| -> Result<CommandOutput, CliError> {
            calls.lock().expect("lock").push(args.to_vec());
            Ok(CommandOutput {
                exit_code: 0,
                stdout: String::new(),
                stderr: String::new(),
            })
        }
    };

    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path"))),
        ],
        || {
            let path = state::launch_agent_path();
            fs::create_dir_all(path.parent().expect("launch agent dir"))
                .expect("create launch agent dir");
            fs::write(&path, "plist").expect("write plist");

            restart_launch_agent_with(&runner).expect("restart launch agent");

            let calls = calls.lock().expect("lock");
            assert_eq!(
                calls[0],
                vec!["bootout".to_string(), launchd_service_target()]
            );
            assert_eq!(
                calls[1],
                vec![
                    "bootstrap".to_string(),
                    launchd_domain_target(),
                    path.display().to_string(),
                ]
            );
            assert_eq!(calls.len(), 2, "bootout + bootstrap only, no kickstart");
        },
    );
}

#[test]
fn best_effort_bootout_returns_true_on_success() {
    let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
    let runner = {
        let calls = Arc::clone(&calls);
        move |args: &[String]| -> Result<CommandOutput, CliError> {
            calls.lock().expect("lock").push(args.to_vec());
            Ok(CommandOutput {
                exit_code: 0,
                stdout: String::new(),
                stderr: String::new(),
            })
        }
    };

    let booted_out = best_effort_bootout(&runner).expect("bootout launch agent");

    assert!(booted_out);
    assert_eq!(
        calls.lock().expect("lock").as_slice(),
        &[vec!["bootout".to_string(), launchd_service_target()]]
    );
}

#[test]
fn best_effort_bootout_returns_false_when_service_is_missing() {
    let booted_out = best_effort_bootout(&|args| {
        assert_eq!(args, &["bootout".to_string(), launchd_service_target()]);
        Ok(CommandOutput {
            exit_code: 1,
            stdout: String::new(),
            stderr: "Could not find service".to_string(),
        })
    })
    .expect("bootout should treat a missing service as success");

    assert!(!booted_out);
}

#[test]
fn restart_launch_agent_requires_installed_plist() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path"))),
        ],
        || {
            let error = restart_launch_agent_with(&|_args| {
                panic!("runner should not be called when plist is missing");
            })
            .expect_err("restart should fail without a plist");
            assert!(error.to_string().contains("launch agent plist not installed"));
        },
    );
}

#[test]
fn parse_launchctl_print_extracts_runtime_fields() {
    let parsed = parse_launchctl_print(
        r#"gui/501/io.harness.daemon = {
    state = waiting
    pid = 98321
    last exit code = 78
}"#,
    );
    assert_eq!(
        parsed,
        LaunchctlPrintStatus {
            state: Some("waiting".to_string()),
            pid: Some(98_321),
            last_exit_status: Some(78),
        }
    );
}

#[test]
fn launch_agent_status_marks_missing_service_as_not_loaded() {
    let status = launch_agent_status_with(&|args| {
        assert_eq!(args.first().map(String::as_str), Some("print"));
        Ok(CommandOutput {
            exit_code: 1,
            stdout: String::new(),
            stderr: "Could not find service \"io.harness.daemon\"".to_string(),
        })
    });
    assert!(!status.loaded);
    assert!(status.status_error.is_none());
}

#[test]
fn launch_agent_status_coalesces_legacy_runtime_into_current_contract() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path"))),
        ],
        || {
            let legacy_path = state::legacy_launch_agent_path();
            fs::create_dir_all(legacy_path.parent().expect("legacy parent"))
                .expect("create legacy launch agent dir");
            fs::write(&legacy_path, "legacy plist").expect("write legacy plist");

            let status = launch_agent_status_with(&|args| {
                assert_eq!(args.first().map(String::as_str), Some("print"));

                if args
                    .get(1)
                    .is_some_and(|value| value == &launchd_service_target())
                {
                    return Ok(CommandOutput {
                        exit_code: 1,
                        stdout: String::new(),
                        stderr: "Could not find service".to_string(),
                    });
                }

                assert_eq!(
                    args.get(1),
                    Some(&launchd_service_target_for(LEGACY_LAUNCH_AGENT_LABEL))
                );
                Ok(CommandOutput {
                    exit_code: 0,
                    stdout: format!(
                        r#"{service} = {{
    state = running
    pid = 4242
    last exit code = 0
}}"#,
                        service = launchd_service_target_for(LEGACY_LAUNCH_AGENT_LABEL)
                    ),
                    stderr: String::new(),
                })
            });

            assert!(status.installed);
            assert!(status.loaded);
            assert_eq!(status.label, LAUNCH_AGENT_LABEL);
            assert_eq!(status.path, state::launch_agent_path().display().to_string());
            assert_eq!(status.service_target, launchd_service_target());
            assert_eq!(status.state.as_deref(), Some("running"));
            assert_eq!(status.pid, Some(4242));
            assert_eq!(status.last_exit_status, Some(0));
        },
    );
}

#[test]
fn bootout_launch_agent_refuses_in_sandbox_mode() {
    let error = bootout_launch_agent(true).expect_err("sandbox mode must refuse bootout");
    assert_eq!(error.code(), "SANDBOX001");
    assert!(error.to_string().contains("launch-agent-bootout"));
}

#[test]
fn restart_launch_agent_refuses_in_sandbox_mode() {
    let error = restart_launch_agent(true).expect_err("sandbox mode must refuse restart");
    assert_eq!(error.code(), "SANDBOX001");
    assert!(error.to_string().contains("launch-agent-restart"));
}

#[test]
fn install_launch_agent_refuses_in_sandbox_mode() {
    let error = install_launch_agent(true, Path::new("/tmp/harness-bin"))
        .expect_err("sandbox mode must refuse install");
    assert_eq!(error.code(), "SANDBOX001");
    assert!(error.to_string().contains("launch-agent-install"));
}

#[test]
fn remove_launch_agent_refuses_in_sandbox_mode() {
    let error = remove_launch_agent(true).expect_err("sandbox mode must refuse remove");
    assert_eq!(error.code(), "SANDBOX001");
    assert!(error.to_string().contains("launch-agent-remove"));
}
