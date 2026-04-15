use super::*;

pub(super) fn install_test_observe_runtime(poll_interval: Duration) {
    let (sender, _) = broadcast::channel(8);
    let _ = OBSERVE_RUNTIME.set(DaemonObserveRuntime {
        sender,
        poll_interval,
        running_sessions: Arc::default(),
        db: Arc::new(OnceLock::new()),
        async_db: Arc::new(OnceLock::new()),
    });
}

pub(super) fn install_test_observe_async_db(async_db: Arc<crate::daemon::db::AsyncDaemonDb>) {
    install_test_observe_runtime(Duration::from_secs(60));
    let runtime = OBSERVE_RUNTIME.get().expect("observe runtime");
    let _ = runtime.async_db.set(async_db);
}

pub(super) fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-session"), || {
            let project = tmp.path().join("project");
            fs::create_dir_all(&project).expect("create project dir");
            let status = Command::new("git")
                .arg("init")
                .arg("-q")
                .arg(&project)
                .status()
                .expect("git init");
            assert!(status.success(), "git init should succeed");
            test_fn(&project);
        });
    });
}

pub(super) fn append_project_ledger_entry(project_dir: &Path) {
    let ledger_path = project_context_dir(project_dir)
        .join("agents")
        .join("ledger")
        .join("events.jsonl");
    fs::create_dir_all(ledger_path.parent().expect("ledger dir")).expect("create ledger dir");
    fs::write(
        &ledger_path,
        format!(
            "{{\"sequence\":1,\"recorded_at\":\"2026-03-28T12:00:00Z\",\"cwd\":\"{}\"}}\n",
            project_dir.display()
        ),
    )
    .expect("write ledger");
}

pub(super) fn write_agent_log(
    project_dir: &Path,
    runtime: HookAgent,
    session_id: &str,
    text: &str,
) {
    let log_path = project_context_dir(project_dir)
        .join("agents/sessions")
        .join(runtime::runtime_for(runtime).name())
        .join(session_id)
        .join("raw.jsonl");
    fs::create_dir_all(log_path.parent().expect("agent log dir")).expect("create log dir");
    fs::write(
        log_path,
        format!(
            "{{\"timestamp\":\"2026-03-28T12:00:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{text}\"}}}}\n"
        ),
    )
    .expect("write log");
}

pub(super) fn write_agent_log_file(project: &Path, runtime: &str, session_id: &str) -> PathBuf {
    let log_path = crate::workspace::project_context_dir(project)
        .join(format!("agents/sessions/{runtime}/{session_id}/raw.jsonl"));
    fs::create_dir_all(log_path.parent().expect("agent log dir")).expect("create log dir");
    fs::write(&log_path, "{}\n").expect("write log");
    log_path
}

pub(super) fn set_log_mtime_seconds_ago(path: &Path, seconds: u64) {
    let old_time = std::time::SystemTime::now() - std::time::Duration::from_secs(seconds);
    std::fs::File::options()
        .write(true)
        .open(path)
        .expect("open for mtime")
        .set_times(std::fs::FileTimes::new().set_modified(old_time))
        .expect("set mtime");
}

#[derive(Clone, Copy)]
pub(super) enum IdleSignalScriptBehavior {
    AckOnWake,
    IgnoreWake,
}

pub(super) fn write_idle_signal_script(
    project: &Path,
    signal_dir: &Path,
    runtime_session_id: &str,
    orchestration_session_id: &str,
    behavior: IdleSignalScriptBehavior,
) -> std::path::PathBuf {
    let script_path = project.join(match behavior {
        IdleSignalScriptBehavior::AckOnWake => "idle-signal-ack.sh",
        IdleSignalScriptBehavior::IgnoreWake => "idle-signal-ignore.sh",
    });
    let wake_behavior = match behavior {
        IdleSignalScriptBehavior::AckOnWake => format!(
            r#"attempt=0
while [ "$attempt" -lt 20 ]; do
  for signal_file in "{signal_dir}/pending"/*.json; do
if [ -e "$signal_file" ]; then
  signal_id=$(basename "$signal_file" .json)
  ack_dir="{signal_dir}/acknowledged"
  mkdir -p "$ack_dir"
  cat > "$ack_dir/$signal_id.ack.json" <<EOF
{{"signal_id":"$signal_id","acknowledged_at":"2026-04-13T00:00:00Z","result":"accepted","agent":"{runtime_session_id}","session_id":"{orchestration_session_id}"}}
EOF
  mv "$signal_file" "$ack_dir/$signal_id.json"
  exit 0
fi
  done
  attempt=$((attempt + 1))
  sleep 0.1
done
exit 1
"#,
            signal_dir = signal_dir.display(),
            runtime_session_id = runtime_session_id,
            orchestration_session_id = orchestration_session_id
        ),
        IdleSignalScriptBehavior::IgnoreWake => "sleep 2\nexit 0\n".to_string(),
    };
    let script = format!(
        r#"#!/bin/sh
while IFS= read -r _line; do
  {wake_behavior}
done
"#
    );
    fs::write(&script_path, script).expect("write idle signal script");
    let mut permissions = fs::metadata(&script_path)
        .expect("script metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&script_path, permissions).expect("set script executable");
    script_path
}

/// Build an in-memory DB with a project and session loaded from files.
pub(super) fn setup_db_with_session(
    project: &Path,
    session_id: &str,
) -> crate::daemon::db::DaemonDb {
    let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open in-memory db");
    let projects = index::discover_projects().expect("discover projects");
    for p in &projects {
        db.sync_project(p).expect("sync project");
    }
    let resolved = index::resolve_session(session_id).expect("resolve session");
    db.sync_session(&resolved.project.project_id, &resolved.state)
        .expect("sync session");
    append_project_ledger_entry(project);
    db
}

pub(super) async fn setup_async_db_with_session(
    project: &Path,
    session_id: &str,
) -> Arc<crate::daemon::db::AsyncDaemonDb> {
    let db_path = project.join("daemon.sqlite");
    let async_db = Arc::new(
        crate::daemon::db::AsyncDaemonDb::connect(&db_path)
            .await
            .expect("open async daemon db"),
    );
    let resolved = index::resolve_session(session_id).expect("resolve session");
    async_db
        .sync_project(&resolved.project)
        .await
        .expect("sync project");
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await
        .expect("save session state");
    append_project_ledger_entry(project);
    async_db
}

/// Build an in-memory DB with a project and session loaded only into
/// SQLite (no files for that session). The session only exists in the DB.
pub(super) fn setup_db_only_session(
    project: &Path,
) -> (
    crate::daemon::db::DaemonDb,
    crate::session::types::SessionState,
) {
    use crate::session::service::build_new_session;

    let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open in-memory db");

    let project_record = index::discovered_project_for_checkout(project);
    db.sync_project(&project_record).expect("sync project");

    let state = build_new_session(
        "db-only test",
        "",
        "db-only-sess",
        "claude",
        Some("test-session"),
        &utc_now(),
    );
    db.sync_session(&project_record.project_id, &state)
        .expect("sync session");
    (db, state)
}

pub(super) fn join_db_codex_worker(
    db: &crate::daemon::db::DaemonDb,
    state: &crate::session::types::SessionState,
    project: &Path,
    runtime_session_id: &str,
) -> String {
    use crate::daemon::protocol::SessionJoinRequest;

    let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some(runtime_session_id))], || {
        join_session_direct(
            &state.session_id,
            &SessionJoinRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec![],
                name: None,
                project_dir: project.to_string_lossy().into(),
                persona: None,
            },
            Some(db),
        )
        .expect("join db worker")
    });
    joined
        .agents
        .keys()
        .find(|agent_id| agent_id.starts_with("codex-"))
        .expect("worker id")
        .clone()
}

pub(super) fn setup_db_with_project(project: &Path) -> crate::daemon::db::DaemonDb {
    let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open db");
    let project_record = index::discovered_project_for_checkout(project);
    db.sync_project(&project_record).expect("sync project");
    db
}
