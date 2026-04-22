use super::*;

/// Verify the full readiness callback flow: start a TUI, call signal_ready
/// from a separate thread (simulating the SessionStart hook), and verify the
/// agent_tui_ready event is broadcast.
#[test]
fn readiness_callback_triggers_agent_tui_ready_event() {
    let tmp = tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let db_path = tmp.path().join("harness.db");
    std::fs::create_dir_all(&project_dir).expect("project dir");

    let db = DaemonDb::open(&db_path).expect("open db");
    let project = harness::daemon::index::discovered_project_for_checkout(&project_dir);
    db.sync_project(&project).expect("sync project");

    let state = temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8")))],
        || {
            harness::session::service::start_session(
                "readiness",
                "readiness callback test",
                &project_dir,
                Some("sess-readiness-cb"),
            )
            .expect("start session")
        },
    );
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
            "sess-readiness-cb",
            &AgentTuiStartRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: vec![],
                name: Some("callback test".into()),
                prompt: None,
                project_dir: Some(project_dir.to_string_lossy().into()),
                persona: None,
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
            Ok(_) => {}
            Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            Err(_) => thread::sleep(Duration::from_millis(20)),
        }
    }
    assert!(
        saw_ready,
        "agent_tui_ready event should be broadcast after callback"
    );

    let _ = manager.stop(&snapshot.tui_id);
}
