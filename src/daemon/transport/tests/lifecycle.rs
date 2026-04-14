use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

use super::super::super::launchd;
use super::super::super::state;
use super::super::control::{restart_daemon_with, spawn_daemon, stop_daemon_with};

pub(super) fn sample_launch_agent_status(
    installed: bool,
    loaded: bool,
) -> launchd::LaunchAgentStatus {
    launchd::LaunchAgentStatus {
        installed,
        loaded,
        label: "io.harness.daemon".to_string(),
        path: "/tmp/io.harness.daemon.plist".to_string(),
        domain_target: "gui/501".to_string(),
        service_target: "gui/501/io.harness.daemon".to_string(),
        state: None,
        pid: None,
        last_exit_status: None,
        status_error: None,
    }
}

fn sample_manifest(endpoint: &str) -> state::DaemonManifest {
    state::DaemonManifest {
        version: "18.3.0".to_string(),
        pid: 42,
        endpoint: endpoint.to_string(),
        started_at: "2026-04-04T00:00:00Z".to_string(),
        token_path: "/tmp/auth-token".to_string(),
        sandboxed: false,
        host_bridge: state::HostBridgeManifest::default(),
        revision: 0,
        updated_at: String::new(),
        binary_stamp: None,
    }
}

#[test]
fn stop_launchd_boots_out_then_reports_stopped() {
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let response = stop_daemon_with(
        true,
        &sample_launch_agent_status(true, true),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("load_manifest".to_string());
                Ok(Some(sample_manifest("http://127.0.0.1:7000")))
            }
        },
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("bootout".to_string());
                Ok(true)
            }
        },
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("request_shutdown".to_string());
                Ok(false)
            }
        },
        {
            let calls = Rc::clone(&calls);
            move |endpoint| {
                calls.borrow_mut().push(format!("wait_shutdown:{endpoint}"));
                Ok(())
            }
        },
    )
    .expect("stop daemon");

    assert_eq!(response.status, "stopped");
    assert_eq!(
        calls.borrow().as_slice(),
        [
            "load_manifest",
            "bootout",
            "wait_shutdown:http://127.0.0.1:7000",
            "request_shutdown",
        ]
    );
}

#[test]
fn stop_launchd_missing_runtime_is_still_success() {
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let response = stop_daemon_with(
        true,
        &sample_launch_agent_status(true, false),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("load_manifest".to_string());
                Ok(Some(sample_manifest("http://127.0.0.1:7001")))
            }
        },
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("bootout".to_string());
                Ok(false)
            }
        },
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("request_shutdown".to_string());
                Ok(false)
            }
        },
        |_endpoint| panic!("shutdown wait should be skipped when bootout reports no runtime"),
    )
    .expect("stop daemon");

    assert_eq!(response.status, "stopped");
    assert_eq!(
        calls.borrow().as_slice(),
        ["load_manifest", "bootout", "request_shutdown"]
    );
}

#[test]
fn stop_without_manifest_returns_success() {
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let response = stop_daemon_with(
        false,
        &sample_launch_agent_status(false, false),
        || panic!("manual stop should not read launchd manifest when launchd is disabled"),
        || panic!("manual stop should not call launchd bootout when launchd is disabled"),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("request_shutdown".to_string());
                Ok(false)
            }
        },
        |_endpoint| panic!("no shutdown wait expected when nothing is running"),
    )
    .expect("stop daemon");

    assert_eq!(response.status, "stopped");
    assert_eq!(calls.borrow().as_slice(), ["request_shutdown"]);
}

#[test]
fn restart_loaded_launch_agent_boots_out_then_uses_launchd_path() {
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let response = restart_daemon_with(
        true,
        &sample_launch_agent_status(true, true),
        Path::new("/tmp/harness"),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("load_manifest".to_string());
                Ok(Some(sample_manifest("http://127.0.0.1:7002")))
            }
        },
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("bootout".to_string());
                Ok(true)
            }
        },
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("request_shutdown".to_string());
                Ok(false)
            }
        },
        {
            let calls = Rc::clone(&calls);
            move |endpoint| {
                calls.borrow_mut().push(format!("wait_shutdown:{endpoint}"));
                Ok(())
            }
        },
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("restart_launch_agent".to_string());
                Ok(())
            }
        },
        |_binary| panic!("manual daemon path should not run when a launch agent is installed"),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("wait_launchd_health".to_string());
                Ok(())
            }
        },
    )
    .expect("restart daemon");

    assert_eq!(response.status, "restarted");
    assert_eq!(
        calls.borrow().as_slice(),
        [
            "load_manifest",
            "bootout",
            "wait_shutdown:http://127.0.0.1:7002",
            "request_shutdown",
            "restart_launch_agent",
            "wait_launchd_health",
        ]
    );
}

#[test]
fn restart_installed_but_offline_launch_agent_skips_manual_spawn() {
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let response = restart_daemon_with(
        true,
        &sample_launch_agent_status(true, false),
        Path::new("/tmp/harness"),
        || panic!("offline launch agent restart should not read the manifest"),
        || panic!("offline launch agent restart should not boot out a missing runtime"),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("request_shutdown".to_string());
                Ok(false)
            }
        },
        |_endpoint| panic!("offline launch agent restart should not wait for shutdown"),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("restart_launch_agent".to_string());
                Ok(())
            }
        },
        |_binary| panic!("manual daemon path should not run when a launch agent is installed"),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("wait_launchd_health".to_string());
                Ok(())
            }
        },
    )
    .expect("restart daemon");

    assert_eq!(response.status, "restarted");
    assert_eq!(
        calls.borrow().as_slice(),
        [
            "request_shutdown",
            "restart_launch_agent",
            "wait_launchd_health"
        ]
    );
}

#[test]
fn restart_manual_path_stops_then_spawns_replacement() {
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let response = restart_daemon_with(
        false,
        &sample_launch_agent_status(false, false),
        Path::new("/tmp/harness"),
        || panic!("manual restart should not read a launchd manifest"),
        || panic!("manual restart should not call launchd bootout"),
        {
            let calls = Rc::clone(&calls);
            move || {
                calls.borrow_mut().push("request_shutdown".to_string());
                Ok(true)
            }
        },
        |_endpoint| panic!("manual restart should not use launchd shutdown waiting"),
        || panic!("manual restart should not restart launchd"),
        {
            let calls = Rc::clone(&calls);
            move |binary| {
                calls
                    .borrow_mut()
                    .push(format!("start_manual:{}", binary.display()));
                Ok(())
            }
        },
        || panic!("manual restart should not wait on launchd health"),
    )
    .expect("restart daemon");

    assert_eq!(response.status, "restarted");
    assert_eq!(
        calls.borrow().as_slice(),
        ["request_shutdown", "start_manual:/tmp/harness"]
    );
}

#[test]
fn spawn_daemon_refuses_in_sandbox_mode() {
    let error = spawn_daemon(true, Path::new("/nonexistent/harness"))
        .expect_err("sandbox mode must refuse spawn");
    assert_eq!(error.code(), "SANDBOX001");
    assert!(error.to_string().contains("daemon-spawn"));
}
