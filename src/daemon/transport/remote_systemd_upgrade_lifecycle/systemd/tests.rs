use std::cell::RefCell;
use std::fs;
use std::path::PathBuf;

use tempfile::tempdir;

use super::*;

fn test_plan(root: &Path) -> RemoteSystemdOperationPlan {
    RemoteSystemdOperationPlan {
        unit: "harness-remote".to_string(),
        binary_path: root.join("harness"),
        unit_path: root.join("harness-remote.service"),
        environment_path: root.join("harness-remote.env"),
        state_path: root.join("state"),
        store_path: root.join("store"),
        controller_path: root.join("controller"),
        readiness_timeout: Duration::from_secs(1),
        stabilization_window: Duration::ZERO,
    }
}

fn output(stdout: impl Into<String>) -> RemoteSystemdCommandOutput {
    RemoteSystemdCommandOutput {
        exit_code: 0,
        stdout: stdout.into(),
        stderr: String::new(),
    }
}

#[test]
fn active_service_without_control_group_is_rejected_before_stop() {
    let temp = tempdir().expect("tempdir");
    let plan = test_plan(temp.path());
    let commands = RefCell::new(Vec::<Vec<String>>::new());
    let run = |args: &[String]| {
        commands.borrow_mut().push(args.to_vec());
        Ok(output(
            "ActiveState=active\nSubState=running\nMainPID=41\nNRestarts=0\nControlGroup=\n",
        ))
    };

    let error = observe_stop_control_group(&plan, &run)
        .expect_err("active unit without a cgroup must fail before mutation");

    assert!(
        error
            .to_string()
            .contains("without an effective systemd ControlGroup")
    );
    let commands = commands.borrow();
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0].first().map(String::as_str), Some("show"));
    assert!(!commands.iter().flatten().any(|argument| argument == "stop"));
}

#[test]
fn active_service_requires_a_populated_recursive_cgroup_before_stop() {
    let temp = tempdir().expect("tempdir");
    let plan = test_plan(temp.path());
    let events_file = temp.path().join("cgroup.events");
    fs::write(&events_file, "populated 0\nfrozen 0\n").expect("write cgroup events");
    let commands = RefCell::new(Vec::<Vec<String>>::new());
    let run = |args: &[String]| {
        commands.borrow_mut().push(args.to_vec());
        Ok(output(format!(
            "ActiveState=active\nSubState=running\nMainPID=41\nNRestarts=0\nControlGroup=/harness-tests/remote\nHarnessTestControlGroupEvents={}\n",
            events_file.display()
        )))
    };

    let error = observe_stop_control_group(&plan, &run)
        .expect_err("active unit with an empty recursive cgroup must fail before mutation");

    assert!(error.to_string().contains("cgroup is unpopulated"));
    let commands = commands.borrow();
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0].first().map(String::as_str), Some("show"));
}

#[test]
fn stopped_service_cgroup_subtree_must_not_remain_populated() {
    let temp = tempdir().expect("tempdir");
    let events_file = temp.path().join("cgroup.events");
    fs::write(temp.path().join("cgroup.procs"), "").expect("write empty direct process list");
    fs::write(&events_file, "populated 1\nfrozen 0\n").expect("write cgroup events");
    let control_group =
        validate_control_group_before_stop(events_file).expect("validate cgroup-v2 evidence");

    let error = require_unpopulated_control_group(Some(&control_group))
        .expect_err("a populated descendant cgroup must fail closed");

    assert!(error.to_string().contains("subtree remains populated"));
}

#[test]
fn cgroup_events_must_prove_the_subtree_is_unpopulated() {
    let temp = tempdir().expect("tempdir");
    let events_file = temp.path().join("cgroup.events");

    fs::write(&events_file, "populated 0\nfrozen 0\n").expect("write cgroup events");
    let control_group =
        validate_control_group_before_stop(events_file).expect("validate cgroup-v2 evidence");
    require_unpopulated_control_group(Some(&control_group))
        .expect("unpopulated subtree is quiescent");
}

#[test]
fn validated_cgroup_may_vanish_after_stop() {
    let temp = tempdir().expect("tempdir");
    let events_file = temp.path().join("cgroup.events");
    fs::write(&events_file, "populated 1\nfrozen 0\n").expect("write cgroup events");
    let control_group = validate_control_group_before_stop(events_file.clone())
        .expect("validate cgroup-v2 evidence before stop");

    fs::remove_file(events_file).expect("simulate systemd removing the stopped cgroup");
    require_unpopulated_control_group(Some(&control_group))
        .expect("a previously validated cgroup may disappear after stop");
}

#[test]
fn missing_or_malformed_cgroup_events_fail_before_stop() {
    let temp = tempdir().expect("tempdir");
    let events_file = temp.path().join("cgroup.events");

    let missing = validate_control_group_before_stop(events_file.clone())
        .expect_err("missing recursive cgroup evidence must fail closed");
    assert!(missing.to_string().contains("before stop"));

    for contents in [
        "",
        "frozen 0\n",
        "populated\n",
        "populated 0 extra\n",
        "populated 0\npopulated 0\n",
        "populated unknown\n",
    ] {
        fs::write(&events_file, contents).expect("write malformed cgroup events");
        validate_control_group_before_stop(events_file.clone())
            .expect_err("unsupported or malformed recursive evidence must fail closed");
    }
}

#[test]
fn control_group_path_must_name_a_non_root_service_cgroup() {
    for control_group in ["/", "relative", "/system.slice/../escape"] {
        let error = cgroup_events_file(control_group)
            .expect_err("unsafe control group path must fail closed");
        assert!(error.to_string().contains("ControlGroup"));
    }
    assert_eq!(
        cgroup_events_file("/system.slice/harness.service").expect("service cgroup path"),
        PathBuf::from("/sys/fs/cgroup/system.slice/harness.service/cgroup.events")
    );
}

#[test]
fn managed_process_environment_requires_exact_protected_assignments() {
    let temp = tempdir().expect("tempdir");
    let plan = test_plan(temp.path());
    let valid = b"RUST_LOG=harness=info\0HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0XDG_DATA_HOME=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/harness-remote\0HARNESS_DAEMON_OWNERSHIP=external\0NON_UTF8=\xff\0";
    process_environment::validate_process_environment(&plan, valid)
        .expect("exact managed process environment");

    for invalid in [
        b"HARNESS_DAEMON_DATA_HOME=/var/lib/stale\0XDG_DATA_HOME=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/harness-remote\0HARNESS_DAEMON_OWNERSHIP=external\0".as_slice(),
        b"HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0XDG_DATA_HOME=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/harness-remote\0".as_slice(),
        b"HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0XDG_DATA_HOME=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/harness-remote\0HARNESS_DAEMON_OWNERSHIP=external\0".as_slice(),
        b"HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0XDG_DATA_HOME=/var/lib/harness-remote\0HARNESS_DAEMON_OWNERSHIP=external\0".as_slice(),
        b"HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0XDG_DATA_HOME=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/stale\0HARNESS_DAEMON_OWNERSHIP=external\0".as_slice(),
        b"HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0XDG_DATA_HOME=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/private/harness-remote\0HARNESS_DAEMON_OWNERSHIP=external\0".as_slice(),
        b"HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote\0XDG_DATA_HOME=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/harness-remote\0STATE_DIRECTORY=/var/lib/harness-remote\0HARNESS_DAEMON_OWNERSHIP=external\0".as_slice(),
    ] {
        process_environment::validate_process_environment(&plan, invalid)
            .expect_err("process environment drift must fail closed");
    }
}

#[test]
fn disappearing_process_environment_is_transient_but_permission_failure_is_not() {
    assert_eq!(
        process_environment::process_disappearance_errors_for_tests(),
        (true, true, false)
    );
}

#[test]
fn process_environment_proof_is_bound_to_pid_and_restart_generation() {
    let before = SystemdObservation {
        active_state: "active".to_string(),
        sub_state: "running".to_string(),
        main_pid: 42,
        n_restarts: 3,
    };
    assert!(process_environment::same_process_generation(
        &before, &before
    ));

    let mut changed_pid = before.clone();
    changed_pid.main_pid = 43;
    assert!(!process_environment::same_process_generation(
        &before,
        &changed_pid
    ));

    let mut changed_restart = before.clone();
    changed_restart.n_restarts = 4;
    assert!(!process_environment::same_process_generation(
        &before,
        &changed_restart
    ));
}
