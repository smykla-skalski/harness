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
        let state = start_active_session(
            project,
            "ae60b5c5-37cf-5a50-a816-8f454bb9e92e",
            "watch test",
        );
        let leader_id = state.leader_id.expect("leader id");

        let joined = temp_env::with_vars(
            [(
                "CODEX_SESSION_ID",
                Some("008d974f-c6a9-53e5-a62e-d331367c449a"),
            )],
            || {
                session_service::join_session(
                    "ae60b5c5-37cf-5a50-a816-8f454bb9e92e",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker")
            },
        );
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
            "ae60b5c5-37cf-5a50-a816-8f454bb9e92e",
            "watch timeline",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");
        append_project_ledger_entry(project);
        let signal = session_service::send_signal(
            "ae60b5c5-37cf-5a50-a816-8f454bb9e92e",
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
        assert!(
            initial
                .session_ids
                .contains("ae60b5c5-37cf-5a50-a816-8f454bb9e92e")
        );

        let signal_dir = runtime::runtime_for_name("codex")
            .expect("codex runtime")
            .signal_dir(project, &worker_session_id);
        acknowledge_signal(
            &signal_dir,
            &SignalAck {
                signal_id: signal.signal.signal_id,
                acknowledged_at: "2026-03-28T12:10:00Z".into(),
                result: AckResult::Accepted,
                agent: "008d974f-c6a9-53e5-a62e-d331367c449a".into(),
                session_id: "ae60b5c5-37cf-5a50-a816-8f454bb9e92e".into(),
                details: Some("applied".into()),
            },
        )
        .expect("ack signal");
        let targeted = BTreeSet::from(["ae60b5c5-37cf-5a50-a816-8f454bb9e92e".to_string()]);
        let changed = refresh_watch_snapshot(&mut snapshot, &targeted, RefreshScope::SessionScoped)
            .expect("changed snapshot");
        assert!(!changed.sessions_updated);
        assert!(
            changed
                .session_ids
                .contains("ae60b5c5-37cf-5a50-a816-8f454bb9e92e")
        );
    });
}
