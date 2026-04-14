use super::*;

#[test]
fn daemon_stop_stops_running_manual_daemon() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "stopped\n");

    wait_for_daemon_stopped(&home, &xdg);
    wait_for_child_exit(&mut daemon);
}

#[test]
fn daemon_restart_starts_manual_daemon_when_offline() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let output = run_harness(&home, &xdg, &["daemon", "restart"]);
    assert!(
        output.status.success(),
        "restart failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "restarted\n");

    let status = wait_for_daemon_ready(&home, &xdg);
    assert!(
        status.manifest.is_some(),
        "restart should create a manifest"
    );

    let stop_output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop failed: {}",
        output_text(&stop_output)
    );
}

#[test]
fn daemon_restart_replaces_running_manual_daemon() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let initial_status = wait_for_daemon_ready(&home, &xdg);
    let initial_pid = initial_status
        .manifest
        .as_ref()
        .expect("initial manifest")
        .pid;

    let output = run_harness(&home, &xdg, &["daemon", "restart"]);
    assert!(
        output.status.success(),
        "restart failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "restarted\n");

    wait_for_child_exit(&mut daemon);
    let restarted_status = wait_for_daemon_ready(&home, &xdg);
    let restarted_pid = restarted_status
        .manifest
        .as_ref()
        .expect("restarted manifest")
        .pid;
    assert_ne!(
        restarted_pid, initial_pid,
        "restart should replace the process"
    );

    let stop_output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop failed: {}",
        output_text(&stop_output)
    );
}

#[test]
fn daemon_only_session_status_and_end_work_after_list() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);
    let project_arg = project.to_str().expect("utf8 project");
    let started = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "daemon-only-session",
        "daemon-only integration",
        "verify daemon-backed session lookup after list",
    );

    let list_output = run_harness(&home, &xdg, &["session", "list", "--json"]);
    assert!(
        list_output.status.success(),
        "session list failed: {}",
        output_text(&list_output)
    );
    let listed: Vec<SessionState> =
        serde_json::from_slice(&list_output.stdout).expect("parse session list");
    assert!(
        listed
            .iter()
            .any(|session| session.session_id == started.session_id)
    );

    let status_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "status",
            "daemon-only-session",
            "--json",
            "--project-dir",
            project_arg,
        ],
    );
    assert!(
        status_output.status.success(),
        "session status failed: {}",
        output_text(&status_output)
    );
    let status: SessionState =
        serde_json::from_slice(&status_output.stdout).expect("parse session status");
    assert_eq!(status.session_id, started.session_id);

    let end_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "end",
            "daemon-only-session",
            "--actor",
            "codex-leader",
            "--project-dir",
            project_arg,
        ],
    );
    assert!(
        end_output.status.success(),
        "session end failed: {}",
        output_text(&end_output)
    );

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}
