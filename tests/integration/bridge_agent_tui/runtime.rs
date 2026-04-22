use super::*;

#[test]
fn bridge_reconfigure_requires_force_to_disable_agent_tui_with_active_sessions() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let project = tmp.path().join("project");
    crate::integration::daemon_control::process::init_git_repo(&project);

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let _state = wait_for_bridge_state(tmp.path());
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "HARNESS_HOST_HOME",
                Some(host_home.to_str().expect("utf8 host home")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", None),
        ],
        || {
            let client = BridgeClient::from_state_file().expect("bridge client");
            let snapshot = client
                .agent_tui_start(&AgentTuiStartSpec {
                    session_id: "session-1".to_string(),
                    agent_id: "agent-1".to_string(),
                    tui_id: "agent-tui-1".to_string(),
                    profile: AgentTuiLaunchProfile::from_argv(
                        "codex",
                        vec!["sh".to_string(), "-c".to_string(), "cat".to_string()],
                    )
                    .expect("launch profile"),
                    project_dir: project.clone(),
                    transcript_path: tmp.path().join("transcript.log"),
                    size: AgentTuiSize { rows: 24, cols: 80 },
                    prompt: None,
                    effort: None,
                })
                .expect("start agent tui");
            assert_eq!(snapshot.tui_id, "agent-tui-1");
        },
    );

    let output = run_bridge(&tmp, &["bridge", "reconfigure", "--disable", "agent-tui"]);
    assert!(
        !output.status.success(),
        "disable should fail without force: {}",
        output_text(&output)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("KSRCLI092") || stderr.contains("--force"));

    let forced_output = run_bridge(
        &tmp,
        &[
            "bridge",
            "reconfigure",
            "--disable",
            "agent-tui",
            "--force",
            "--json",
        ],
    );
    assert!(
        forced_output.status.success(),
        "forced disable: {}",
        output_text(&forced_output)
    );
    let report: BridgeStatusReport =
        serde_json::from_slice(&forced_output.stdout).expect("parse status");
    assert!(!report.capabilities.contains_key("agent-tui"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}

#[test]
fn bridge_does_not_resend_auto_join_for_cli_prompt_runtimes() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let project = tmp.path().join("project");
    crate::integration::daemon_control::process::init_git_repo(&project);

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let _state = wait_for_bridge_state(tmp.path());
    let prompt = "/harness:harness session join sess-cli-runtime --role worker --runtime claude";

    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "HARNESS_HOST_HOME",
                Some(host_home.to_str().expect("utf8 host home")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", None),
        ],
        || {
            let client = BridgeClient::from_state_file().expect("bridge client");
            let snapshot = client
                .agent_tui_start(&AgentTuiStartSpec {
                    session_id: "sess-cli-runtime".to_string(),
                    agent_id: "agent-cli-runtime".to_string(),
                    tui_id: "agent-tui-cli-runtime".to_string(),
                    profile: AgentTuiLaunchProfile::from_argv(
                        "claude",
                        vec![
                            "sh".to_string(),
                            "-c".to_string(),
                            "printf '\\342\\225\\255 ready\\n'; printf '%s\\n' \"$@\"; sleep 0.3; cat"
                                .to_string(),
                            "sh".to_string(),
                        ],
                    )
                    .expect("launch profile"),
                    project_dir: project.clone(),
                    transcript_path: tmp.path().join("cli-runtime-transcript.log"),
                    size: AgentTuiSize { rows: 24, cols: 80 },
                    prompt: Some(prompt.to_string()),
                    effort: None,
                })
                .expect("start agent tui");
            assert_eq!(snapshot.tui_id, "agent-tui-cli-runtime");

            let deadline = Instant::now() + Duration::from_secs(5);
            let latest = loop {
                let latest = client
                    .agent_tui_get("agent-tui-cli-runtime")
                    .expect("refresh snapshot");
                if latest.screen.text.contains(prompt) {
                    break latest;
                }
                assert!(
                    Instant::now() < deadline,
                    "initial CLI prompt never appeared in bridge-managed screen"
                );
                thread::sleep(Duration::from_millis(50));
            };
            assert_eq!(latest.screen.text.matches(prompt).count(), 1);

            thread::sleep(Duration::from_millis(700));

            let settled = client
                .agent_tui_get("agent-tui-cli-runtime")
                .expect("refresh settled snapshot");
            assert_eq!(
                settled.screen.text.matches(prompt).count(),
                1,
                "CLI prompt runtimes must not receive the same auto-join twice"
            );
        },
    );

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}

#[test]
fn sandboxed_agent_tui_publishes_live_refresh_over_bridge() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let project = tmp.path().join("project");
    crate::integration::daemon_control::process::init_git_repo(&project);

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let _state = wait_for_bridge_state(tmp.path());

    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "HARNESS_HOST_HOME",
                Some(host_home.to_str().expect("utf8 host home")),
            ),
            ("HOME", Some(host_home.to_str().expect("utf8 host home"))),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", Some("1")),
        ],
        || {
            let db_path = tmp.path().join("daemon.sqlite3");
            let db = DaemonDb::open(&db_path).expect("open daemon db");
            let session_state = daemon_service::start_session_direct(
                &SessionStartRequest {
                    title: "sandboxed tui live refresh".into(),
                    context: "sandboxed tui".into(),
                    session_id: Some("sess-sandbox-tui".into()),
                    project_dir: project.to_string_lossy().into_owned(),
                    policy_preset: None,
                    base_ref: None,
                },
                Some(&db),
            )
            .expect("start session");
            let session_id = session_state.session_id.clone();

            let db_slot = Arc::new(OnceLock::new());
            db_slot.set(Arc::new(Mutex::new(db))).expect("install db");
            let (sender, mut receiver) = broadcast::channel::<StreamEvent>(64);
            let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

            let snapshot = manager
                .start(
                    &session_id,
                    &AgentTuiStartRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: Some("Sandboxed live refresh".into()),
                        prompt: None,
                        project_dir: Some(project.to_string_lossy().into_owned()),
                        argv: vec![
                            "sh".into(),
                            "-c".into(),
                            "printf 'agent-ready\\n'; sleep 2".into(),
                        ],
                        rows: 30,
                        cols: 120,
                        persona: None,
                        model: None,
                        effort: None,
                        allow_custom_model: false,
                    },
                )
                .expect("start sandboxed tui via bridge");
            assert_eq!(snapshot.status, AgentTuiStatus::Running);

            let started = receiver.try_recv().expect("started event must be queued");
            assert_eq!(started.event, "agent_tui_started");

            let mut updated: Option<AgentTuiSnapshot> = None;
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline && updated.is_none() {
                match receiver.try_recv() {
                    Ok(event) => {
                        if event.event != "agent_tui_updated" {
                            continue;
                        }
                        let event_snapshot: AgentTuiSnapshot =
                            serde_json::from_value(event.payload.clone())
                                .expect("decode updated snapshot");
                        if event_snapshot.tui_id == snapshot.tui_id
                            && event_snapshot.screen.text.contains("agent-ready")
                        {
                            updated = Some(event_snapshot);
                        }
                    }
                    Err(broadcast::error::TryRecvError::Empty) => {
                        thread::sleep(Duration::from_millis(20));
                    }
                    Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                    Err(broadcast::error::TryRecvError::Closed) => {
                        panic!("broadcast channel closed before receiving live refresh event");
                    }
                }
            }

            let updated = updated.expect(
                "sandboxed daemon should publish an agent_tui_updated event whose screen text contains the PTY output",
            );
            assert_eq!(updated.tui_id, snapshot.tui_id);
            assert!(updated.screen.text.contains("agent-ready"));
            assert!(
                updated.status == AgentTuiStatus::Running
                    || updated.status == AgentTuiStatus::Exited
            );

            let _ = manager.stop(&snapshot.tui_id);
        },
    );

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}
