use tempfile::tempdir;

use harness::daemon::db::DaemonDb;
use harness::daemon::service;
use harness::daemon::state::{self, DaemonManifest};
use harness::session::service as session_service;
use harness::session::types::{SessionRole, TaskSeverity};
use harness::workspace::utc_now;

/// Seed two projects with sessions, agents, tasks, and a daemon manifest.
fn seed_workspace(tmp: &std::path::Path) {
    state::ensure_daemon_dirs().expect("dirs");

    let manifest = DaemonManifest {
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: std::process::id(),
        endpoint: "http://127.0.0.1:0".to_string(),
        started_at: utc_now(),
        token_path: state::auth_token_path().display().to_string(),
    };
    state::write_manifest(&manifest).expect("write manifest");
    state::append_event("info", "comparison test started").expect("event");

    let project_a = tmp.join("project-a");
    let project_b = tmp.join("project-b");
    fs_err::create_dir_all(&project_a).expect("create project a");
    fs_err::create_dir_all(&project_b).expect("create project b");

    for project in [&project_a, &project_b] {
        std::process::Command::new("git")
            .arg("-C")
            .arg(project)
            .args(["init"])
            .status()
            .expect("git init");
    }

    let state_a =
        session_service::start_session("comparison-a", &project_a, Some("claude"), Some("cmp1"))
            .expect("start cmp1");
    session_service::join_session("cmp1", SessionRole::Worker, "codex", &[], None, &project_a)
        .expect("join cmp1");

    let state_b =
        session_service::start_session("comparison-b", &project_b, Some("claude"), Some("cmp2"))
            .expect("start cmp2");

    for (session_id, project_dir, session_state) in [
        ("cmp1", project_a.as_path(), &state_a),
        ("cmp2", project_b.as_path(), &state_b),
    ] {
        let leader = session_state
            .agents
            .keys()
            .find(|id| id.starts_with("claude"))
            .expect("leader agent");
        for i in 0..2 {
            session_service::create_task(
                session_id,
                &format!("cmp task {i}"),
                Some("comparison context"),
                TaskSeverity::Low,
                leader,
                project_dir,
            )
            .expect("create task");
        }
    }
}

fn normalize_json(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            for v in map.values_mut() {
                normalize_json(v);
            }
        }
        serde_json::Value::Array(arr) => {
            for v in arr.iter_mut() {
                normalize_json(v);
            }
            // Sort arrays of objects by their string representation for
            // order-independent comparison.
            arr.sort_by(|a, b| a.to_string().cmp(&b.to_string()));
        }
        _ => {}
    }
}

fn to_normalized_json<T: serde::Serialize>(value: &T) -> serde_json::Value {
    let mut json = serde_json::to_value(value).expect("serialize");
    normalize_json(&mut json);
    json
}

#[ignore]
#[test]
fn file_and_db_reads_produce_identical_output() {
    let tmp = tempdir().expect("tempdir");
    let xdg = tmp.path().to_str().expect("utf8").to_string();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.as_str())),
            ("CLAUDE_SESSION_ID", Some("comparison-session")),
        ],
        || seed_workspace(tmp.path()),
    );

    let db_path = tmp.path().join("harness/daemon/harness.db");
    let db = DaemonDb::open(&db_path).expect("open db");
    temp_env::with_vars([("XDG_DATA_HOME", Some(xdg.as_str()))], || {
        db.import_from_files()
    })
    .expect("import");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.as_str())),
            ("CLAUDE_SESSION_ID", Some("comparison-session")),
        ],
        || {
            let manifest = state::load_manifest().expect("manifest").expect("present");

            // --- list_projects ---
            let file_projects = service::list_projects(None).expect("file projects");
            let db_projects = service::list_projects(Some(&db)).expect("db projects");
            assert_eq!(
                to_normalized_json(&file_projects),
                to_normalized_json(&db_projects),
                "list_projects diverged"
            );

            // --- list_sessions ---
            let file_sessions = service::list_sessions(true, None).expect("file sessions");
            let db_sessions = service::list_sessions(true, Some(&db)).expect("db sessions");
            assert_eq!(
                to_normalized_json(&file_sessions),
                to_normalized_json(&db_sessions),
                "list_sessions diverged"
            );

            // --- health_response ---
            let file_health = service::health_response(&manifest, None).expect("file health");
            let db_health = service::health_response(&manifest, Some(&db)).expect("db health");
            // Compare counts only (endpoint/version/uptime are identical).
            assert_eq!(
                file_health.project_count, db_health.project_count,
                "health project_count diverged"
            );
            assert_eq!(
                file_health.session_count, db_health.session_count,
                "health session_count diverged"
            );

            // --- session_detail ---
            let file_detail = service::session_detail("cmp1", None).expect("file detail");
            let db_detail = service::session_detail("cmp1", Some(&db)).expect("db detail");
            let file_json = to_normalized_json(&file_detail);
            let db_json = to_normalized_json(&db_detail);
            // Compare key fields (full JSON may differ in ordering of
            // signals/activity which are loaded differently).
            assert_eq!(
                file_json["session_id"], db_json["session_id"],
                "detail session_id diverged"
            );
            assert_eq!(
                file_json["agents"], db_json["agents"],
                "detail agents diverged"
            );
            assert_eq!(
                file_json["tasks"], db_json["tasks"],
                "detail tasks diverged"
            );

            // --- session_timeline ---
            let file_timeline = service::session_timeline("cmp1", None).expect("file timeline");
            let db_timeline = service::session_timeline("cmp1", Some(&db)).expect("db timeline");
            assert_eq!(
                file_timeline.len(),
                db_timeline.len(),
                "timeline entry count diverged: file={} db={}",
                file_timeline.len(),
                db_timeline.len()
            );
        },
    );
}
