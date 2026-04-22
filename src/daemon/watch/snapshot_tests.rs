use std::collections::BTreeSet;

use crate::agents::runtime;
use crate::agents::runtime::signal::{AckResult, SignalAck, acknowledge_signal};
use crate::session::service as session_service;
use crate::session::types::{SessionRole, TaskSeverity};

use super::refresh::refresh_watch_snapshot;
use super::state::{RefreshScope, WatchSnapshot};
use super::test_support::{append_project_ledger_entry, start_active_session, with_temp_project};

#[test]
fn refresh_watch_snapshot_detects_timeline_only_changes() {
    with_temp_project(|project| {
        let state = start_active_session(project, "watch-sess", "watch test");
        let leader_id = state.leader_id.expect("leader id");

        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
            session_service::join_session(
                "watch-sess",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker")
        });
        let worker_id = joined
            .agents
            .keys()
            .find(|agent_id| agent_id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let worker_session_id = joined
            .agents
            .get(&worker_id)
            .and_then(|agent| agent.agent_session_id.clone())
            .expect("worker session id");
        session_service::create_task(
            "watch-sess",
            "watch timeline",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");
        append_project_ledger_entry(project);
        let signal = session_service::send_signal(
            "watch-sess",
            &worker_id,
            "inject_context",
            "watch the ack path",
            Some("timeline"),
            &leader_id,
            project,
        )
        .expect("send signal");

        let mut snapshot = WatchSnapshot::default();
        let initial = refresh_watch_snapshot(&mut snapshot, &BTreeSet::new(), RefreshScope::Full)
            .expect("initial snapshot");
        assert!(initial.sessions_updated);
        assert!(initial.session_ids.contains("watch-sess"));

        let signal_dir = runtime::runtime_for_name("codex")
            .expect("codex runtime")
            .signal_dir(project, &worker_session_id);
        acknowledge_signal(
            &signal_dir,
            &SignalAck {
                signal_id: signal.signal.signal_id,
                acknowledged_at: "2026-03-28T12:10:00Z".into(),
                result: AckResult::Accepted,
                agent: "worker-session".into(),
                session_id: "watch-sess".into(),
                details: Some("applied".into()),
            },
        )
        .expect("ack signal");
        let targeted = BTreeSet::from(["watch-sess".to_string()]);
        let changed = refresh_watch_snapshot(&mut snapshot, &targeted, RefreshScope::SessionScoped)
            .expect("changed snapshot");
        assert!(!changed.sessions_updated);
        assert!(changed.session_ids.contains("watch-sess"));
    });
}
