use tempfile::tempdir;

use super::super::{load_signals_for, session_detail_from_resolved_with_db};
use super::support::{build_project, sample_signal_with_idempotency, sample_state_for_runtime};
use crate::daemon::index::ResolvedSession;
use crate::session::types::{SessionSignalRecord, SessionSignalStatus};

#[test]
fn load_signals_for_filters_shared_runtime_session_history() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let shared_runtime_session = "codex-shared-session";
            let session_one = "sess-alpha";
            let session_two = "sess-beta";

            let alpha_state =
                sample_state_for_runtime(session_one, "codex", shared_runtime_session);
            let beta_state = sample_state_for_runtime(session_two, "codex", shared_runtime_session);

            let shared_signal_dir = context_root
                .join("agents")
                .join("signals")
                .join("codex")
                .join(shared_runtime_session);
            crate::agents::runtime::signal::write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-alpha",
                    "signal for alpha",
                    Some("sess-alpha:codex-worker:inject_context"),
                ),
            )
            .expect("write alpha signal");
            crate::agents::runtime::signal::write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-beta",
                    "signal for beta",
                    Some("sess-beta:codex-worker:inject_context"),
                ),
            )
            .expect("write beta signal");

            let project = build_project(context_root);

            let alpha_signals = load_signals_for(&project, &alpha_state).expect("alpha signals");
            let beta_signals = load_signals_for(&project, &beta_state).expect("beta signals");

            assert_eq!(alpha_signals.len(), 1);
            assert_eq!(alpha_signals[0].signal.signal_id, "sig-alpha");
            assert_eq!(beta_signals.len(), 1);
            assert_eq!(beta_signals[0].signal.signal_id, "sig-beta");
        },
    );
}

#[test]
fn session_detail_with_db_refreshes_shared_runtime_signal_index() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let shared_runtime_session = "codex-shared-session";
            let session_one = "sess-alpha";
            let session_two = "sess-beta";
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
            crate::agents::runtime::signal::write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-alpha",
                    "signal for alpha",
                    Some("sess-alpha:codex-worker:inject_context"),
                ),
            )
            .expect("write alpha signal");
            crate::agents::runtime::signal::write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-beta",
                    "signal for beta",
                    Some("sess-beta:codex-worker:inject_context"),
                ),
            )
            .expect("write beta signal");

            let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open db");
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
                            Some("sess-alpha:codex-worker:inject_context"),
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
                            Some("sess-beta:codex-worker:inject_context"),
                        ),
                        acknowledgment: None,
                    },
                ],
            )
            .expect("seed stale alpha index");

            let alpha_detail = session_detail_from_resolved_with_db(
                &ResolvedSession {
                    project: project.clone(),
                    state: alpha_state,
                },
                &db,
            )
            .expect("alpha detail");
            let beta_detail = session_detail_from_resolved_with_db(
                &ResolvedSession {
                    project: project.clone(),
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
