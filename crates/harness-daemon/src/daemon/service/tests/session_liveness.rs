use std::collections::BTreeSet;

use super::*;
use crate::session::storage;

#[test]
fn list_sessions_reads_cached_liveness_state_within_ttl() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon cached liveness summaries",
            "d43a3183-eee5-5ca4-8a7a-1c52cfe43839",
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
            "30ffa13f-e939-5012-acf8-2cd29b1843b5",
        );
        let stale = (chrono::Utc::now() - chrono::Duration::seconds(1_200)).to_rfc3339();
        let layout =
            storage::layout_from_project_dir(project, &fixture.state.session_id).expect("layout");
        storage::update_state(&layout, |state| {
            state.last_activity_at = Some(stale.clone());
            for agent in state.agents.values_mut() {
                agent.last_activity_at = Some(stale.clone());
                agent.updated_at = stale.clone();
            }
            Ok(())
        })
        .expect("age session activity");
        set_log_mtime_seconds_ago(&fixture.leader_log, 1_200);
        set_log_mtime_seconds_ago(&fixture.worker_log, 1_200);

        let liveness = session_service::sync_agent_liveness(&fixture.state.session_id, project)
            .expect("sync dead liveness");
        assert_eq!(liveness.disconnected.len(), 2);

        let db = setup_db_with_session(project, &fixture.state.session_id);
        clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);

        let layout = storage::layout_from_project_dir(project, &fixture.state.session_id)
            .expect("layout from project");
        let state_path = layout.state_file();
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
fn list_sessions_reconciles_orphaned_active_session_without_state_file() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon orphaned liveness summaries",
            "eddfddfc-1f15-595e-8bf5-da249a790b38",
        );
        let stale = (chrono::Utc::now() - chrono::Duration::seconds(1_200)).to_rfc3339();
        let mut stale_state = fixture.state.clone();
        stale.clone_into(&mut stale_state.updated_at);
        stale_state.last_activity_at = Some(stale.clone());
        for agent in stale_state.agents.values_mut() {
            agent.joined_at = stale.clone();
            stale.clone_into(&mut agent.updated_at);
            agent.last_activity_at = Some(stale.clone());
        }

        let db = setup_db_with_project(project);
        let project_id = index::discovered_project_for_checkout(project).project_id;
        db.sync_session(&project_id, &stale_state).expect("sync");
        clear_session_liveness_refresh_cache_entry(&stale_state.session_id);

        let layout = storage::layout_from_project_dir(project, &stale_state.session_id)
            .expect("layout from project");
        let state_dir = layout.session_root();
        fs::remove_dir_all(&state_dir).expect("remove state dir");
        fs::remove_file(&fixture.leader_log).expect("remove leader log");
        fs::remove_file(&fixture.worker_log).expect("remove worker log");

        let summary = list_sessions(true, Some(&db))
            .expect("session summaries")
            .into_iter()
            .find(|summary| summary.session_id == stale_state.session_id)
            .expect("summary");
        assert_eq!(summary.status, SessionStatus::LeaderlessDegraded);
        assert!(summary.leader_id.is_none());
        assert_eq!(summary.metrics.agent_count, 0);
        assert_eq!(summary.metrics.active_agent_count, 0);

        let persisted = db
            .load_session_state(&stale_state.session_id)
            .expect("load state")
            .expect("session present");
        assert_eq!(persisted.status, SessionStatus::LeaderlessDegraded);
        assert!(persisted.leader_id.is_none());
        assert!(
            persisted
                .agents
                .values()
                .all(|agent| agent.status.is_disconnected())
        );
    });
}

#[test]
fn session_detail_async_reconciles_orphaned_active_session_without_state_file() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon async orphaned liveness detail",
            "6bf4cb7c-8872-507e-833e-cc3451deea36",
        );
        let stale = (chrono::Utc::now() - chrono::Duration::seconds(1_200)).to_rfc3339();
        let mut stale_state = fixture.state.clone();
        stale.clone_into(&mut stale_state.updated_at);
        stale_state.last_activity_at = Some(stale.clone());
        for agent in stale_state.agents.values_mut() {
            agent.joined_at = stale.clone();
            stale.clone_into(&mut agent.updated_at);
            agent.last_activity_at = Some(stale.clone());
        }

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &fixture.state.session_id).await;
            let project_id = index::discovered_project_for_checkout(project).project_id;
            async_db
                .save_session_state(&project_id, &stale_state)
                .await
                .expect("save stale state");
            clear_session_liveness_refresh_cache_entry(&stale_state.session_id);

            let layout = storage::layout_from_project_dir(project, &stale_state.session_id)
                .expect("layout from project");
            let state_dir = layout.session_root();
            fs::remove_dir_all(&state_dir).expect("remove state dir");
            fs::remove_file(&fixture.leader_log).expect("remove leader log");
            fs::remove_file(&fixture.worker_log).expect("remove worker log");

            let detail = session_detail_async(&stale_state.session_id, Some(async_db.as_ref()))
                .await
                .expect("session detail");
            assert_eq!(detail.session.status, SessionStatus::LeaderlessDegraded);
            assert!(detail.session.leader_id.is_none());
            assert_eq!(detail.session.metrics.agent_count, 0);
            assert_eq!(detail.session.metrics.active_agent_count, 0);
            assert!(detail.agents.is_empty());

            let resolved = async_db
                .resolve_session(&stale_state.session_id)
                .await
                .expect("resolve session")
                .expect("session present");
            assert_eq!(resolved.state.status, SessionStatus::LeaderlessDegraded);
            assert!(resolved.state.leader_id.is_none());
            assert!(
                resolved
                    .state
                    .agents
                    .values()
                    .all(|agent| agent.status.is_disconnected())
            );
        });
    });
}

#[test]
fn background_liveness_refresh_updates_async_summary_without_explicit_read() {
    with_temp_project(|project| {
        let state = start_active_file_session(
            "daemon background liveness refresh",
            "",
            project,
            Some("claude"),
            Some("dd3d7e14-fbea-5adb-9c79-787edaf06b42"),
        )
        .expect("start active session");
        let leader_id = state.leader_id.clone().expect("leader id");
        let leader = state.agents.get(&leader_id).expect("leader agent");

        age_leader_state_activity(project, &state.session_id, 1_200);
        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader
                .agent_session_id
                .as_deref()
                .expect("leader runtime session"),
        );
        set_log_mtime_seconds_ago(&leader_log, 1_200);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &state.session_id).await;
            clear_session_liveness_refresh_cache_entry(&state.session_id);

            let baseline_change_seq = async_db
                .load_change_tracking_since(0)
                .await
                .expect("load initial change tracking")
                .into_iter()
                .map(|(_, change_seq)| change_seq)
                .max()
                .unwrap_or(0);

            let summary_before = async_db
                .list_session_summaries()
                .await
                .expect("list summaries before background refresh")
                .into_iter()
                .find(|summary| summary.session_id == state.session_id)
                .expect("summary before background refresh");
            assert_eq!(summary_before.status, SessionStatus::Active);
            assert_eq!(
                summary_before.leader_id.as_deref(),
                state.leader_id.as_deref()
            );
            assert_eq!(summary_before.metrics.agent_count, 1);
            assert_eq!(summary_before.metrics.active_agent_count, 1);

            reconcile_active_session_liveness_background_async(Some(async_db.as_ref()))
                .await
                .expect("refresh background liveness");

            let summary_after = async_db
                .list_session_summaries()
                .await
                .expect("list summaries after background refresh")
                .into_iter()
                .find(|summary| summary.session_id == state.session_id)
                .expect("summary after background refresh");
            assert_eq!(summary_after.status, SessionStatus::LeaderlessDegraded);
            assert!(summary_after.leader_id.is_none());
            assert_eq!(summary_after.metrics.agent_count, 0);
            assert_eq!(summary_after.metrics.active_agent_count, 0);

            let changes = async_db
                .load_change_tracking_since(baseline_change_seq)
                .await
                .expect("load background liveness changes");
            assert!(
                changes
                    .iter()
                    .any(|(scope, _)| scope == &format!("session:{}", state.session_id)),
                "background liveness refresh should bump the session scope"
            );
            assert!(
                changes.iter().any(|(scope, _)| scope == "global"),
                "background liveness refresh should bump the global scope"
            );
        });
    });
}

#[test]
fn list_sessions_keeps_recent_db_only_session_live_without_state_file() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        clear_session_liveness_refresh_cache_entry(&state.session_id);

        let summary = list_sessions(true, Some(&db))
            .expect("session summaries")
            .into_iter()
            .find(|summary| summary.session_id == state.session_id)
            .expect("summary");
        assert_eq!(summary.status, SessionStatus::Active);
        assert_eq!(summary.leader_id.as_deref(), state.leader_id.as_deref());
        assert_eq!(summary.metrics.agent_count, 1);
        assert_eq!(summary.metrics.active_agent_count, 1);
    });
}

#[test]
fn stale_session_ids_for_liveness_refresh_skips_recent_sessions() {
    let now = Instant::now();
    let mut cache = BTreeMap::new();

    let first = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")]),
        now,
    );
    assert_eq!(
        first,
        vec![String::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")]
    );

    let second = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")]),
        now + Duration::from_secs(1),
    );
    assert!(second.is_empty(), "recent sessions should be skipped");

    let third = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")]),
        now + SESSION_LIVENESS_REFRESH_TTL + Duration::from_secs(1),
    );
    assert_eq!(
        third,
        vec![String::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")]
    );
}

#[test]
fn session_liveness_refresh_due_locked_gates_within_ttl() {
    let now = Instant::now();
    let mut cache = BTreeMap::new();
    let session_id = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

    assert!(
        session_liveness_refresh_due_locked(&mut cache, session_id, now),
        "first read of an untracked session is always due"
    );
    assert!(
        !session_liveness_refresh_due_locked(&mut cache, session_id, now + Duration::from_secs(1)),
        "a read within the TTL window is skipped"
    );
    assert!(
        session_liveness_refresh_due_locked(
            &mut cache,
            session_id,
            now + SESSION_LIVENESS_REFRESH_TTL + Duration::from_secs(1),
        ),
        "a read past the TTL window is due again"
    );
}

#[test]
fn session_liveness_refresh_due_locked_does_not_evict_other_sessions() {
    let now = Instant::now();
    let mut cache = BTreeMap::new();
    let first = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";
    let second = "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4";

    assert!(session_liveness_refresh_due_locked(&mut cache, first, now));
    assert!(session_liveness_refresh_due_locked(&mut cache, second, now));
    // Reading `second` must not have reset `first`'s refresh point.
    assert!(
        !session_liveness_refresh_due_locked(&mut cache, first, now + Duration::from_secs(1)),
        "an unrelated session's read must not make this one due again"
    );
}
