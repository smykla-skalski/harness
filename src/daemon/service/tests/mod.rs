use super::*;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};

use fs_err as fs;
use tempfile::tempdir;
use tokio::sync::broadcast;

use crate::agents::runtime;
use crate::daemon::agent_tui::{AgentTuiManagerHandle, AgentTuiStartRequest};
use crate::daemon::protocol::{SessionUpdatedPayload, SessionsUpdatedPayload};
use crate::hooks::adapters::HookAgent;
use crate::session::{
    service as session_service,
    types::{AgentStatus, SessionRole, SessionSignalStatus, SessionStatus},
};
use crate::workspace::project_context_dir;
use harness_testkit::with_isolated_harness_env;

mod support;
use support::*;

mod async_signals;
mod async_stream;
mod background_import;
mod config;
mod diagnostics;
mod direct_session_bootstrap;
mod direct_session_leader;
mod direct_session_start;
mod direct_sessions;
mod leave;
mod observe;
mod session_liveness;
mod session_reads;
mod signal_reconciliation;
mod signals;
mod stream_initial_events;
mod task_mutations;
mod timeline;

#[test]
fn daemon_service_round_trip_smoke_covers_public_surface() {
    use crate::daemon::protocol::{
        SessionEndRequest, SessionsUpdatedPayload, SignalCancelRequest, SignalSendRequest,
        TaskCreateRequest,
    };

    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon service smoke",
            "round trip",
            project,
            Some("claude"),
            Some("daemon-service-smoke"),
        )
        .expect("start session");
        let leader_id = state.leader_id.clone().expect("leader id");
        let joined = temp_env::with_vars(
            [("CODEX_SESSION_ID", Some("daemon-service-smoke-worker"))],
            || {
                session_service::join_session(
                    &state.session_id,
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

        let created = create_task(
            &state.session_id,
            &TaskCreateRequest {
                actor: leader_id.clone(),
                title: "repair daemon split".into(),
                context: Some("keep internal helpers wired".into()),
                severity: crate::session::types::TaskSeverity::High,
                suggested_fix: Some("re-export crate-private session helpers".into()),
            },
            None,
        )
        .expect("create task");
        let task_id = created.tasks[0].task_id.clone();

        let sent = send_signal(
            &state.session_id,
            &SignalSendRequest {
                actor: leader_id.clone(),
                agent_id: worker_id.clone(),
                command: "inject_context".into(),
                message: "double-check the daemon split".into(),
                action_hint: Some("task:daemon-service-smoke".into()),
            },
            None,
            None,
        )
        .expect("send signal");
        let signal_id = sent.signals[0].signal.signal_id.clone();

        let cancelled = cancel_signal(
            &state.session_id,
            &SignalCancelRequest {
                actor: leader_id.clone(),
                agent_id: worker_id.clone(),
                signal_id: signal_id.clone(),
            },
            None,
        )
        .expect("cancel signal");
        assert_eq!(
            cancelled
                .signals
                .iter()
                .find(|signal| signal.signal.signal_id == signal_id)
                .expect("cancelled signal")
                .status,
            SessionSignalStatus::Rejected
        );

        let detail = session_detail(&state.session_id, None).expect("session detail");
        assert_eq!(detail.session.session_id, state.session_id);
        assert_eq!(detail.tasks.len(), 1);
        assert_eq!(detail.tasks[0].task_id, task_id);
        let updated = session_updated_event(&state.session_id, None).expect("event");
        let payload: SessionUpdatedPayload =
            serde_json::from_value(updated.payload).expect("deserialize payload");
        assert_eq!(payload.detail.session.session_id, state.session_id);
        let sessions = sessions_updated_event(None).expect("sessions updated");
        let payload: SessionsUpdatedPayload =
            serde_json::from_value(sessions.payload).expect("deserialize sessions payload");
        assert_eq!(payload.sessions.len(), 1);

        let ended = end_session(
            &state.session_id,
            &SessionEndRequest { actor: leader_id },
            None,
        )
        .expect("end session");
        assert_eq!(ended.session.status, SessionStatus::Ended);
    });
}
