use super::*;
use harness_testkit::{init_git_repo_with_seed, with_isolated_harness_env};

/// Well under `READINESS_TIMEOUT` (10s), so a bridge-hosted agent that only
/// receives its prompts after the blind-send fallback fails this bound.
const CALLBACK_DELIVERY_TIMEOUT: Duration = Duration::from_secs(5);

/// Run `body` against a sandboxed manager whose starts route through a real
/// host bridge, with a session already tracked in the daemon DB.
fn with_sandboxed_bridge_manager(
    label: &str,
    body: impl FnOnce(&AgentTuiManagerHandle, &BridgeClient, &str, &PathBuf),
) {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let project = tmp.path().join("project");
    crate::integration::daemon_control::process::init_git_repo(&project);

    let mut bridge = ManagedChild::spawn(
        Command::new(bridge_binary())
            .args(["start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env_isolated_home(&host_home)
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
            let db = DaemonDb::open(&tmp.path().join("daemon.sqlite3")).expect("open daemon db");
            let session_state = daemon_service::start_session_direct(
                &SessionStartRequest {
                    title: label.into(),
                    context: label.into(),
                    session_id: Some(session_uuid(label)),
                    project_dir: project.to_string_lossy().into_owned(),
                    policy_preset: None,
                    base_ref: None,
                },
                Some(&db),
            )
            .expect("start session");

            let db_slot = Arc::new(OnceLock::new());
            db_slot.set(Arc::new(Mutex::new(db))).expect("install db");
            let (sender, _receiver) = broadcast::channel::<StreamEvent>(64);
            let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);
            let client = BridgeClient::from_state_file().expect("bridge client");

            body(&manager, &client, &session_state.session_id, &project);
        },
    );

    let stop_output = run_bridge(&tmp, &["stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}

/// Start a codex terminal agent: no readiness pattern and no screen-text
/// fallback, so only the `SessionStart` callback can release the join.
fn start_bridge_codex_tui(
    manager: &AgentTuiManagerHandle,
    session_id: &str,
    project: &PathBuf,
    name: &str,
    prompt: Option<String>,
) -> AgentTuiSnapshot {
    manager
        .start(
            session_id,
            &AgentTuiStartRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: vec![],
                name: Some(name.into()),
                prompt,
                project_dir: Some(project.to_string_lossy().into_owned()),
                persona: None,
                task_id: None,
                board_item_id: None,
                workflow_execution_id: None,
                argv: vec!["sh".into(), "-c".into(), "cat".into()],
                rows: 30,
                cols: 120,
                model: None,
                effort: None,
                allow_custom_model: false,
            },
        )
        .expect("start sandboxed tui via bridge")
}

fn wait_for_bridge_screen(
    client: &BridgeClient,
    tui_id: &str,
    needle: &str,
    timeout: Duration,
) -> String {
    let deadline = Instant::now() + timeout;
    loop {
        let snapshot = client
            .agent_tui_get(tui_id)
            .expect("refresh bridge snapshot");
        if snapshot.screen.text.contains(needle) {
            return snapshot.screen.text;
        }
        assert!(
            Instant::now() < deadline,
            "'{needle}' never reached the bridge-hosted PTY within {timeout:?}: {}",
            snapshot.screen.text
        );
        thread::sleep(Duration::from_millis(50));
    }
}

/// A sandboxed daemon holds no process handle for a bridge-hosted terminal
/// agent, so the `SessionStart` readiness callback has to reach the bridge.
/// Without it the join is typed blind after the readiness timeout and lost.
#[test]
fn sandboxed_readiness_callback_releases_the_bridge_hosted_join() {
    with_sandboxed_bridge_manager(
        "sess-bridge-readiness",
        |manager, client, session_id, project| {
            let snapshot =
                start_bridge_codex_tui(manager, session_id, project, "bridge readiness", None);
            assert_eq!(snapshot.status, AgentTuiStatus::Running);

            manager
                .signal_ready(&snapshot.tui_id)
                .expect("readiness callback must reach the bridge-hosted terminal agent");

            wait_for_bridge_screen(
                client,
                &snapshot.tui_id,
                "harness session join",
                CALLBACK_DELIVERY_TIMEOUT,
            );

            let _ = manager.stop(&snapshot.tui_id);
        },
    );
}

/// The bridge start path used to forward only the auto-join, so the prompt the
/// user typed when creating the agent was dropped.
#[test]
fn sandboxed_start_delivers_the_user_prompt_over_the_bridge() {
    with_sandboxed_bridge_manager(
        "sess-bridge-user-prompt",
        |manager, client, session_id, project| {
            let snapshot = start_bridge_codex_tui(
                manager,
                session_id,
                project,
                "bridge user prompt",
                Some("USERPROMPTMARKER".into()),
            );

            manager
                .signal_ready(&snapshot.tui_id)
                .expect("readiness callback must reach the bridge-hosted terminal agent");

            let screen = wait_for_bridge_screen(
                client,
                &snapshot.tui_id,
                "USERPROMPTMARKER",
                CALLBACK_DELIVERY_TIMEOUT,
            );
            let join = screen
                .find("harness session join")
                .expect("auto-join must precede the user prompt");
            let user = screen.find("USERPROMPTMARKER").expect("user prompt");
            assert!(join < user, "{screen}");

            let _ = manager.stop(&snapshot.tui_id);
        },
    );
}

/// Verify the full readiness callback flow: start a TUI, call `signal_ready`
/// from a separate thread (simulating the `SessionStart` hook), and verify the
/// `agent_tui_ready` event is broadcast.
#[test]
fn readiness_callback_triggers_agent_tui_ready_event() {
    let tmp = tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let db_path = tmp.path().join("harness.db");
    init_git_repo_with_seed(&project_dir);

    let db = DaemonDb::open(&db_path).expect("open db");
    let project = harness::daemon::index::discovered_project_for_checkout(&project_dir);
    db.sync_project(&project).expect("sync project");
    let session_id = session_uuid("sess-readiness-cb");

    let state = with_isolated_harness_env(tmp.path(), || {
        harness::session::service::start_session(
            "readiness",
            "readiness callback test",
            &project_dir,
            Some(&session_id),
        )
        .expect("start session")
    });
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, mut receiver) = broadcast::channel(16);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

    let snapshot = manager
        .start(
            &session_id,
            &AgentTuiStartRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: vec![],
                name: Some("callback test".into()),
                prompt: None,
                project_dir: Some(project_dir.to_string_lossy().into()),
                persona: None,
                task_id: None,
                board_item_id: None,
                workflow_execution_id: None,
                argv: vec!["sh".into(), "-c".into(), "printf 'ready\\n'; cat".into()],
                rows: 30,
                cols: 120,
                model: None,
                effort: None,
                allow_custom_model: false,
            },
        )
        .expect("start TUI");
    assert_eq!(snapshot.status, AgentTuiStatus::Running);

    let manager_clone = manager.clone();
    let tui_id = snapshot.tui_id.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(200));
        let _ = manager_clone.signal_ready(&tui_id);
    });

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut saw_ready = false;
    while Instant::now() < deadline && !saw_ready {
        match receiver.try_recv() {
            Ok(event) if event.event == "agent_tui_ready" => saw_ready = true,
            Ok(_) | Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            Err(_) => thread::sleep(Duration::from_millis(20)),
        }
    }
    assert!(
        saw_ready,
        "agent_tui_ready event should be broadcast after callback"
    );

    let _ = manager.stop(&snapshot.tui_id);
}
