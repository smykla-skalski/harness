use std::collections::BTreeSet;

use super::*;

#[test]
fn list_sessions_reads_cached_liveness_state_within_ttl() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon cached liveness summaries",
            "daemon-cached-liveness-summaries",
        );
        let db = setup_db_with_session(project, &fixture.state.session_id);
        clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);

        let first_summary = list_sessions(true, Some(&db))
            .expect("first session summaries")
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("first summary");
        assert_eq!(first_summary.leader_id, fixture.state.leader_id);
        assert_eq!(first_summary.metrics.agent_count, 2);
        assert_eq!(first_summary.metrics.active_agent_count, 2);

        set_log_mtime_seconds_ago(&fixture.leader_log, 600);

        let second_summary = list_sessions(true, Some(&db))
            .expect("second session summaries")
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("second summary");
        assert_eq!(
            second_summary.leader_id, fixture.state.leader_id,
            "cached liveness should defer leader cleanup within the TTL"
        );
        assert_eq!(second_summary.metrics.agent_count, 2);
        assert_eq!(second_summary.metrics.active_agent_count, 2);
    });
}

#[test]
fn list_sessions_skips_liveness_disk_probe_when_db_session_has_no_live_agents() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon dead-session summaries",
            "daemon-dead-session-summaries",
        );
        set_log_mtime_seconds_ago(&fixture.leader_log, 600);
        set_log_mtime_seconds_ago(&fixture.worker_log, 600);

        let liveness = session_service::sync_agent_liveness(&fixture.state.session_id, project)
            .expect("sync dead liveness");
        assert_eq!(liveness.disconnected.len(), 2);

        let db = setup_db_with_session(project, &fixture.state.session_id);
        clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);

        let state_path = crate::workspace::project_context_dir(project)
            .join("orchestration")
            .join("sessions")
            .join(&fixture.state.session_id)
            .join("state.json");
        fs::write(&state_path, "{not-valid-json").expect("corrupt state");

        let summary = list_sessions(true, Some(&db))
            .expect("session summaries should stay on the db fast path")
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("summary");
        assert!(summary.leader_id.is_none());
        assert_eq!(summary.metrics.agent_count, 0);
        assert_eq!(summary.metrics.active_agent_count, 0);
    });
}

#[test]
fn stale_session_ids_for_liveness_refresh_skips_recent_sessions() {
    let now = Instant::now();
    let mut cache = BTreeMap::new();

    let first = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("sess-1")]),
        now,
    );
    assert_eq!(first, vec![String::from("sess-1")]);

    let second = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("sess-1")]),
        now + Duration::from_secs(1),
    );
    assert!(second.is_empty(), "recent sessions should be skipped");

    let third = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("sess-1")]),
        now + SESSION_LIVENESS_REFRESH_TTL + Duration::from_secs(1),
    );
    assert_eq!(third, vec![String::from("sess-1")]);
}
