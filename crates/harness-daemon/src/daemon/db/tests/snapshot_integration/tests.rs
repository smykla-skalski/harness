use tempfile::tempdir;

use crate::daemon::index::ResolvedSession;
use crate::session::types::SessionSignalStatus;

use super::*;

#[test]
fn snapshot_round_trip_smoke_covers_public_surface() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("snapshot-round-trip-smoke")),
        ],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let session_id = "b5f69752-76b7-5e74-b38f-ab709a833e60";
            seed_snapshot_fixture(&context_root, session_id);

            let projects = daemon_snapshot::project_summaries().expect("project summaries");
            let sessions = daemon_snapshot::session_summaries(true).expect("session summaries");
            let detail = daemon_snapshot::session_detail(session_id).expect("session detail");
            let resolved = daemon_index::resolve_session(session_id).expect("resolve session");
            let detail_from_resolved =
                daemon_snapshot::session_detail_from_resolved(&resolved).expect("resolved detail");
            let core = daemon_snapshot::build_session_detail_core(&resolved);
            let extensions = daemon_snapshot::build_session_extensions(&resolved, None)
                .expect("session extensions");
            let activity =
                daemon_snapshot::load_agent_activity_for(&resolved.project, &resolved.state)
                    .expect("activity");
            let signals = daemon_snapshot::load_signals_for(&resolved.project, &resolved.state)
                .expect("signals");
            let db = DaemonDb::open_in_memory().expect("open db");
            let db = crate::daemon::db_handle::DaemonDbOwnedHandle(db);
            db.sync_project(&resolved.project).expect("sync project");
            db.sync_session(&resolved.project.project_id, &resolved.state)
                .expect("sync session");
            let detail_from_db =
                daemon_snapshot::session_detail_from_resolved_with_db(&resolved, &db)
                    .expect("db detail");

            assert_eq!(projects.len(), 1);
            assert_eq!(projects[0].project_id, "project-alpha");
            assert_eq!(projects[0].total_session_count, 1);
            assert_eq!(sessions.len(), 1);
            assert_eq!(sessions[0].session_id, session_id);
            assert_eq!(detail.session.session_id, session_id);
            assert_eq!(detail_from_resolved.session.session_id, session_id);
            assert_eq!(detail_from_db.session.session_id, session_id);
            assert_eq!(detail.signals.len(), 2);
            assert_eq!(signals.len(), detail.signals.len());
            assert_eq!(detail.agent_activity.len(), 1);
            assert_eq!(activity.len(), detail.agent_activity.len());
            assert_eq!(
                detail.observer.as_ref().expect("observer").open_issue_count,
                1
            );
            assert_eq!(detail_from_db.signals.len(), detail.signals.len());
            assert_eq!(
                detail_from_db
                    .observer
                    .as_ref()
                    .expect("observer")
                    .open_issue_count,
                1
            );
            assert!(core.signals.is_empty());
            assert!(core.observer.is_none());
            assert!(core.agent_activity.is_empty());
            assert_eq!(extensions.session_id, session_id);
            assert_eq!(extensions.signals.as_ref().map(Vec::len), Some(2));
            assert_eq!(extensions.agent_activity.as_ref().map(Vec::len), Some(1));
            assert_eq!(
                detail_from_resolved
                    .agent_activity
                    .first()
                    .and_then(|summary| summary.latest_tool_name.as_deref()),
                Some("Read")
            );
        },
    );
}

#[test]
fn snapshot_summary_and_detail_preserve_adoption_metadata() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("snapshot-adoption-metadata")),
        ],
        || {
            let context_root = tmp.path().join("harness/projects/project-adopted");
            let session_id = "7b0bd761-6a0b-5a7f-9147-69a5cc647f67";
            let state_path = context_root
                .join("orchestration")
                .join("sessions")
                .join(session_id)
                .join("state.json");
            seed_snapshot_fixture(&context_root, session_id);

            let mut state = sample_state(session_id);
            state.external_origin = Some("/external/session-root".into());
            state.adopted_at = Some("2026-04-20T02:03:04Z".into());
            write_json(&state_path, &state);

            let summaries = daemon_snapshot::session_summaries(true).expect("session summaries");
            let detail = daemon_snapshot::session_detail(session_id).expect("session detail");
            let resolved = daemon_index::resolve_session(session_id).expect("resolve session");
            let detail_from_resolved =
                daemon_snapshot::session_detail_from_resolved(&resolved).expect("resolved detail");
            let db = DaemonDb::open_in_memory().expect("open db");
            let db = crate::daemon::db_handle::DaemonDbOwnedHandle(db);
            db.sync_project(&resolved.project).expect("sync project");
            db.sync_session(&resolved.project.project_id, &resolved.state)
                .expect("sync session");
            let detail_from_db =
                daemon_snapshot::session_detail_from_resolved_with_db(&resolved, &db)
                    .expect("db detail");

            assert_eq!(
                summaries[0].external_origin.as_deref(),
                Some("/external/session-root")
            );
            assert_eq!(
                summaries[0].adopted_at.as_deref(),
                Some("2026-04-20T02:03:04Z")
            );
            assert_eq!(
                detail.session.external_origin.as_deref(),
                Some("/external/session-root")
            );
            assert_eq!(
                detail.session.adopted_at.as_deref(),
                Some("2026-04-20T02:03:04Z")
            );
            assert_eq!(
                detail_from_resolved.session.external_origin.as_deref(),
                Some("/external/session-root")
            );
            assert_eq!(
                detail_from_resolved.session.adopted_at.as_deref(),
                Some("2026-04-20T02:03:04Z")
            );
            assert_eq!(
                detail_from_db.session.external_origin.as_deref(),
                Some("/external/session-root")
            );
            assert_eq!(
                detail_from_db.session.adopted_at.as_deref(),
                Some("2026-04-20T02:03:04Z")
            );
        },
    );
}

#[test]
fn session_detail_with_db_refreshes_shared_runtime_signal_index() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("snapshot-shared-runtime-refresh")),
        ],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let shared_runtime_session = "codex-shared-session";
            let session_one = "0c3be78e-656d-52d3-b4c3-03ba64d373ac";
            let session_two = "17625cc4-8be6-5f38-b1d6-e2342db78d57";
            let alpha_state =
                sample_state_for_runtime(session_one, "codex", shared_runtime_session);
            let beta_state = sample_state_for_runtime(session_two, "codex", shared_runtime_session);
            let project = build_project(context_root);

            let shared_signal_dir = project
                .context_root
                .join("agents")
                .join("signals")
                .join("codex")
                .join(shared_runtime_session);
            write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-alpha",
                    "signal for alpha",
                    Some("0c3be78e-656d-52d3-b4c3-03ba64d373ac:codex-worker:inject_context"),
                ),
            )
            .expect("write alpha signal");
            write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-beta",
                    "signal for beta",
                    Some("17625cc4-8be6-5f38-b1d6-e2342db78d57:codex-worker:inject_context"),
                ),
            )
            .expect("write beta signal");

            let db = DaemonDb::open_in_memory().expect("open db");
            let db = crate::daemon::db_handle::DaemonDbOwnedHandle(db);
            db.sync_project(&project).expect("sync project");
            db.sync_session(&project.project_id, &alpha_state)
                .expect("sync alpha state");
            db.sync_session(&project.project_id, &beta_state)
                .expect("sync beta state");
            db.sync_signal_index(
                session_one,
                &[
                    SessionSignalRecord {
                        runtime: "codex".into(),
                        agent_id: "codex-worker".into(),
                        session_id: session_one.into(),
                        status: SessionSignalStatus::Pending,
                        signal: sample_signal_with_idempotency(
                            "sig-alpha",
                            "stale alpha row",
                            Some(
                                "0c3be78e-656d-52d3-b4c3-03ba64d373ac:codex-worker:inject_context",
                            ),
                        ),
                        acknowledgment: None,
                    },
                    SessionSignalRecord {
                        runtime: "codex".into(),
                        agent_id: "codex-worker".into(),
                        session_id: session_one.into(),
                        status: SessionSignalStatus::Pending,
                        signal: sample_signal_with_idempotency(
                            "sig-beta",
                            "misattributed beta row",
                            Some(
                                "17625cc4-8be6-5f38-b1d6-e2342db78d57:codex-worker:inject_context",
                            ),
                        ),
                        acknowledgment: None,
                    },
                ],
            )
            .expect("seed stale alpha index");

            let alpha_detail = daemon_snapshot::session_detail_from_resolved_with_db(
                &ResolvedSession {
                    project: project.clone(),
                    state: alpha_state,
                },
                &db,
            )
            .expect("alpha detail");
            let beta_detail = daemon_snapshot::session_detail_from_resolved_with_db(
                &ResolvedSession {
                    project,
                    state: beta_state,
                },
                &db,
            )
            .expect("beta detail");

            assert_eq!(alpha_detail.signals.len(), 1);
            assert_eq!(alpha_detail.signals[0].signal.signal_id, "sig-alpha");
            assert_eq!(
                alpha_detail.signals[0].signal.payload.message,
                "signal for alpha"
            );
            assert_eq!(beta_detail.signals.len(), 1);
            assert_eq!(beta_detail.signals[0].signal.signal_id, "sig-beta");
            assert_eq!(
                beta_detail.signals[0].signal.payload.message,
                "signal for beta"
            );

            let alpha_index = db.load_signals(session_one).expect("reload alpha index");
            let beta_index = db.load_signals(session_two).expect("reload beta index");
            assert_eq!(alpha_index.len(), 1);
            assert_eq!(alpha_index[0].signal.signal_id, "sig-alpha");
            assert_eq!(beta_index.len(), 1);
            assert_eq!(beta_index[0].signal.signal_id, "sig-beta");
        },
    );
}
