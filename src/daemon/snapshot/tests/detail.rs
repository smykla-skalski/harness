use tempfile::tempdir;

use super::super::{
    build_session_detail_core, build_session_extensions, load_agent_activity_for, load_signals_for,
    project_summaries, session_detail, session_detail_from_resolved,
    session_detail_from_resolved_with_db, session_summaries,
};
use crate::daemon::db::DaemonDb;
use crate::daemon::index;

use super::support::{
    sample_state, sample_state_for_runtime, sample_work_item, seed_snapshot_fixture, write_json,
    write_json_line,
};
use crate::session::types::{AgentRegistration, AgentStatus, SessionRole, TaskSeverity};

#[test]
fn snapshot_round_trip_smoke_covers_public_surface() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let session_id = "sess-round-trip";
            seed_snapshot_fixture(&context_root, session_id);

            let projects = project_summaries().expect("project summaries");
            let sessions = session_summaries(true).expect("session summaries");
            let detail = session_detail(session_id).expect("session detail");
            let resolved = index::resolve_session(session_id).expect("resolve session");
            let detail_from_resolved =
                session_detail_from_resolved(&resolved).expect("resolved detail");
            let core = build_session_detail_core(&resolved);
            let extensions = build_session_extensions(&resolved, None).expect("session extensions");
            let activity =
                load_agent_activity_for(&resolved.project, &resolved.state).expect("activity");
            let signals = load_signals_for(&resolved.project, &resolved.state).expect("signals");
            let db = DaemonDb::open_in_memory().expect("open db");
            db.sync_project(&resolved.project).expect("sync project");
            db.sync_session(&resolved.project.project_id, &resolved.state)
                .expect("sync session");
            let detail_from_db =
                session_detail_from_resolved_with_db(&resolved, &db).expect("db detail");

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
fn session_detail_includes_signals_observer_and_cache() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let session_id = "sess-merge";
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
                        == crate::session::types::SessionSignalStatus::Delivered)
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
                crate::observe::types::IssueCategory::AgentCoordination
            );
            assert_eq!(open_issue.fingerprint, "fingerprint");
            assert_eq!(open_issue.first_seen_line, 8);
            assert_eq!(
                open_issue.evidence_excerpt.as_deref(),
                Some("No checkpoint for 12 minutes.")
            );
            assert_eq!(
                detail.observer.as_ref().expect("observer").muted_codes,
                vec![crate::observe::types::IssueCode::AgentRepeatedError]
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
fn snapshot_summary_and_detail_preserve_adoption_metadata() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-adopted");
            let session_id = "sess-adopted";
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

            let summaries = session_summaries(true).expect("session summaries");
            let detail = session_detail(session_id).expect("session detail");
            let resolved = index::resolve_session(session_id).expect("resolve session");
            let detail_from_resolved =
                session_detail_from_resolved(&resolved).expect("resolved detail");
            let db = DaemonDb::open_in_memory().expect("open db");
            db.sync_project(&resolved.project).expect("sync project");
            db.sync_session(&resolved.project.project_id, &resolved.state)
                .expect("sync session");
            let detail_from_db =
                session_detail_from_resolved_with_db(&resolved, &db).expect("db detail");

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
fn session_detail_applies_shared_agent_and_task_ordering() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-ordering");
            let session_id = "sess-ordering";
            let state_path = context_root
                .join("orchestration")
                .join("sessions")
                .join(session_id)
                .join("state.json");

            let mut state = sample_state(session_id);
            state.agents.insert(
                "leader-1".into(),
                AgentRegistration {
                    agent_id: "leader-1".into(),
                    name: "Leader".into(),
                    runtime: "claude".into(),
                    role: SessionRole::Leader,
                    capabilities: vec![],
                    joined_at: "2026-03-28T13:58:00Z".into(),
                    updated_at: "2026-03-28T14:06:00Z".into(),
                    status: AgentStatus::Active,
                    agent_session_id: Some("leader-session".into()),
                    last_activity_at: Some("2026-03-28T14:06:00Z".into()),
                    current_task_id: None,
                    runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
                    persona: None,
                },
            );
            state.agents.insert(
                "reviewer-1".into(),
                AgentRegistration {
                    agent_id: "reviewer-1".into(),
                    name: "Reviewer".into(),
                    runtime: "codex".into(),
                    role: SessionRole::Reviewer,
                    capabilities: vec![],
                    joined_at: "2026-03-28T14:01:00Z".into(),
                    updated_at: "2026-03-28T14:05:00Z".into(),
                    status: AgentStatus::Active,
                    agent_session_id: Some("reviewer-session".into()),
                    last_activity_at: Some("2026-03-28T14:05:00Z".into()),
                    current_task_id: None,
                    runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
                    persona: None,
                },
            );
            state.leader_id = Some("leader-1".into());

            state.tasks.insert(
                "task-a".into(),
                sample_work_item(
                    "task-a",
                    TaskSeverity::Critical,
                    "2026-03-28T13:00:00Z",
                    "2026-03-28T14:00:00Z",
                ),
            );
            state.tasks.insert(
                "task-b".into(),
                sample_work_item(
                    "task-b",
                    TaskSeverity::Critical,
                    "2026-03-28T13:10:00Z",
                    "2026-03-28T14:00:00Z",
                ),
            );
            state.tasks.insert(
                "task-c".into(),
                sample_work_item(
                    "task-c",
                    TaskSeverity::High,
                    "2026-03-28T13:20:00Z",
                    "2026-03-28T14:05:00Z",
                ),
            );

            write_json(&state_path, &state);

            let detail = session_detail(session_id).expect("detail");
            let agent_order: Vec<_> = detail
                .agents
                .into_iter()
                .map(|agent| agent.agent_id)
                .collect();
            assert_eq!(agent_order, vec!["leader-1", "reviewer-1", "codex-worker"]);

            let task_order: Vec<_> = detail.tasks.into_iter().map(|task| task.task_id).collect();
            assert_eq!(task_order, vec!["task-b", "task-a", "task-c"]);
        },
    );
}

#[test]
fn session_detail_agent_activity_falls_back_to_ledger_for_copilot() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let session_id = "sess-copilot";
            let state_path = context_root
                .join("orchestration")
                .join("sessions")
                .join(session_id)
                .join("state.json");
            write_json(
                &state_path,
                &sample_state_for_runtime(session_id, "copilot", "copilot-session-1"),
            );

            let ledger_path = context_root.join("agents/ledger/events.jsonl");
            write_json_line(
                &ledger_path,
                &serde_json::json!({
                    "sequence": 1,
                    "recorded_at": "2026-03-28T14:04:45Z",
                    "agent": "copilot",
                    "session_id": "copilot-session-1",
                    "skill": "suite",
                    "event": "before_tool_use",
                    "hook": "tool-guard",
                    "decision": "allow",
                    "payload": serde_json::json!({
                        "timestamp": "2026-03-28T14:04:45Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "name": "Read",
                                "input": {"path": "README.md"},
                                "id": "call-read-1",
                            }]
                        }
                    }),
                }),
            );
            write_json_line(
                &ledger_path,
                &serde_json::json!({
                    "sequence": 2,
                    "recorded_at": "2026-03-28T14:04:46Z",
                    "agent": "copilot",
                    "session_id": "copilot-session-1",
                    "skill": "suite",
                    "event": "after_tool_use",
                    "hook": "tool-result",
                    "decision": "allow",
                    "payload": serde_json::json!({
                        "timestamp": "2026-03-28T14:04:46Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_result",
                                "tool_name": "Read",
                                "tool_use_id": "call-read-1",
                                "content": {"line_count": 12},
                                "is_error": false,
                            }]
                        }
                    }),
                }),
            );

            let detail = session_detail(session_id).expect("detail");
            assert_eq!(detail.agent_activity.len(), 1);
            assert_eq!(detail.agent_activity[0].agent_id, "copilot-worker");
            assert_eq!(detail.agent_activity[0].runtime, "copilot");
            assert_eq!(detail.agent_activity[0].tool_invocation_count, 1);
            assert_eq!(detail.agent_activity[0].tool_result_count, 1);
            assert_eq!(detail.agent_activity[0].tool_error_count, 0);
            assert_eq!(
                detail.agent_activity[0].latest_tool_name.as_deref(),
                Some("Read")
            );
        },
    );
}
