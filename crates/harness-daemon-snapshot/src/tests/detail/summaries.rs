use harness_session::service as session_service;
use harness_session::storage;
use harness_session::types::{AgentStatus, SessionMetrics, SessionRole, SessionStatus};
use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use crate::tests::support::{sample_state, seed_snapshot_fixture, write_json};
use crate::{session_detail, session_summaries};

// `snapshot_round_trip_smoke_covers_public_surface` and
// `snapshot_summary_and_detail_preserve_adoption_metadata` live in
// `harness-daemon`'s own `daemon::db::tests::snapshot_integration` instead of
// here: both need a real `DaemonDb`, and this crate dev-depending on
// `harness-daemon` for that would create a dev-dependency cycle (this crate
// is `harness-daemon`'s own ordinary dependency), which Cargo resolves by
// compiling this crate twice - once per side of the cycle - producing two
// distinct instances of its `SnapshotStorage` trait that `DaemonDb` only
// implements for one.

#[test]
fn session_detail_includes_signals_observer_and_cache() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let session_id = "7d8914ed-1073-56a6-85c1-0582a49cf5ce";
            seed_snapshot_fixture(&context_root, session_id);

            let detail = session_detail(session_id).expect("detail");
            assert_eq!(detail.session.session_id, session_id);
            assert_eq!(detail.agents.len(), 1);
            assert_eq!(detail.signals.len(), 2);
            assert_eq!(detail.agent_activity.len(), 1);
            assert_eq!(detail.agent_activity[0].agent_id, "codex-worker");
            assert_eq!(detail.agent_activity[0].tool_invocation_count, 1);
            assert_eq!(detail.agent_activity[0].tool_result_count, 1);
            assert_eq!(detail.agent_activity[0].tool_error_count, 0);
            assert_eq!(
                detail.agent_activity[0].latest_tool_name.as_deref(),
                Some("Read")
            );
            assert_eq!(detail.agent_activity[0].recent_tools, vec!["Read"]);
            assert_eq!(
                detail
                    .signals
                    .iter()
                    .filter(|record| record.status
                        == harness_session::types::SessionSignalStatus::Delivered)
                    .count(),
                1
            );
            assert_eq!(
                detail.observer.as_ref().expect("observer").open_issue_count,
                1
            );
            assert_eq!(
                detail
                    .observer
                    .as_ref()
                    .expect("observer")
                    .active_worker_count,
                1
            );
            assert_eq!(
                detail
                    .observer
                    .as_ref()
                    .expect("observer")
                    .resolved_issue_count,
                1
            );
            let open_issue = detail
                .observer
                .as_ref()
                .expect("observer")
                .open_issues
                .first()
                .expect("open issue");
            assert_eq!(open_issue.summary, "worker stalled");
            assert_eq!(
                open_issue.category,
                harness_observe::types::IssueCategory::AgentCoordination
            );
            assert_eq!(open_issue.fingerprint, "fingerprint");
            assert_eq!(open_issue.first_seen_line, 8);
            assert_eq!(
                open_issue.evidence_excerpt.as_deref(),
                Some("No checkpoint for 12 minutes.")
            );
            assert_eq!(
                detail.observer.as_ref().expect("observer").muted_codes,
                vec![harness_observe::types::IssueCode::AgentRepeatedError]
            );
            assert_eq!(
                detail
                    .observer
                    .as_ref()
                    .expect("observer")
                    .active_workers
                    .first()
                    .and_then(|worker| worker.runtime.as_deref()),
                Some("codex")
            );
            assert_eq!(
                detail
                    .observer
                    .as_ref()
                    .expect("observer")
                    .active_workers
                    .first()
                    .and_then(|worker| worker.agent_id.as_deref()),
                Some("codex-worker")
            );
        },
    );
}

#[test]
fn session_detail_preserves_idle_agent_status() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let session_id = "9ffbd4b8-f504-5df4-a711-42e7ccbeefdb";
            let state_path = context_root
                .join("orchestration")
                .join("sessions")
                .join(session_id)
                .join("state.json");
            seed_snapshot_fixture(&context_root, session_id);

            let mut state = sample_state(session_id);
            state.agents.get_mut("codex-worker").expect("worker").status = AgentStatus::Idle;
            state.metrics = SessionMetrics::recalculate(&state);
            write_json(&state_path, &state);

            let detail = session_detail(session_id).expect("session detail");
            assert_eq!(detail.agents.len(), 1);
            assert_eq!(detail.agents[0].status, AgentStatus::Idle);
            assert_eq!(detail.session.metrics.active_agent_count, 0);
            assert_eq!(detail.session.metrics.idle_agent_count, 1);
        },
    );
}

#[test]
fn session_summaries_default_visibility_includes_awaiting_leader_active_and_leaderless_degraded() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project_dir = tmp.path().join("project-snapshot");

        let awaiting = session_service::start_session(
            "awaiting snapshot",
            "",
            &project_dir,
            Some("156471e8-c265-5312-8945-5d5ef789bcc8"),
        )
        .expect("start awaiting session");

        let active = session_service::start_session(
            "active snapshot",
            "",
            &project_dir,
            Some("db0f4f1a-3c08-5dfd-ac2f-3aa42ec8b019"),
        )
        .expect("start active seed");
        let active = temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-active"), || {
            session_service::join_session(
                &active.session_id,
                SessionRole::Leader,
                "claude",
                &[],
                Some("leader"),
                &project_dir,
                None,
            )
        })
        .expect("join active leader");

        let degraded = session_service::start_session(
            "degraded snapshot",
            "",
            &project_dir,
            Some("b946e7d9-00f5-5f30-a1c6-1c240c5cb2ea"),
        )
        .expect("start degraded seed");
        let degraded = temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-degraded"), || {
            session_service::join_session(
                &degraded.session_id,
                SessionRole::Leader,
                "claude",
                &[],
                Some("leader"),
                &project_dir,
                None,
            )
        })
        .expect("join degraded leader");
        let degraded_leader = degraded.leader_id.clone().expect("degraded leader");
        let degraded_layout =
            storage::layout_from_project_dir(&project_dir, &degraded.session_id).expect("layout");
        storage::update_state(&degraded_layout, |state| {
            state.status = SessionStatus::LeaderlessDegraded;
            state.leader_id = None;
            state
                .agents
                .get_mut(&degraded_leader)
                .expect("degraded leader")
                .status = AgentStatus::disconnected_unknown();
            Ok(())
        })
        .expect("degrade session");

        let ended = session_service::start_session(
            "ended snapshot",
            "",
            &project_dir,
            Some("cb529bee-9b4e-57a9-a905-423db769e015"),
        )
        .expect("start ended seed");
        let ended = temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-ended"), || {
            session_service::join_session(
                &ended.session_id,
                SessionRole::Leader,
                "claude",
                &[],
                Some("leader"),
                &project_dir,
                None,
            )
        })
        .expect("join ended leader");
        session_service::end_session_local(
            &ended.session_id,
            ended.leader_id.as_deref().expect("ended leader"),
            &project_dir,
        )
        .expect("end session");

        let visible_ids = session_summaries(false)
            .expect("visible summaries")
            .into_iter()
            .map(|summary| summary.session_id)
            .collect::<Vec<_>>();
        assert!(visible_ids.iter().any(|id| id == &awaiting.session_id));
        assert!(visible_ids.iter().any(|id| id == &active.session_id));
        assert!(visible_ids.iter().any(|id| id == &degraded.session_id));
        assert!(!visible_ids.iter().any(|id| id == &ended.session_id));

        let all_ids = session_summaries(true)
            .expect("all summaries")
            .into_iter()
            .map(|summary| summary.session_id)
            .collect::<Vec<_>>();
        assert!(all_ids.iter().any(|id| id == &awaiting.session_id));
        assert!(all_ids.iter().any(|id| id == &active.session_id));
        assert!(all_ids.iter().any(|id| id == &degraded.session_id));
        assert!(all_ids.iter().any(|id| id == &ended.session_id));
    });
}
