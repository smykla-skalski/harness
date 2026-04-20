use std::path::Path;

use fs_err as fs;
use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::tempdir;

use super::*;
use crate::hooks::protocol::context::{
    AgentContext, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::session::storage as session_storage;
use crate::session::types::{SessionRole, SessionTransition};

fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-session"), || {
            let project = tmp.path().join("project");
            fs::create_dir_all(&project).expect("create project dir");
            test_fn(&project);
        });
    });
}

#[test]
fn collect_signal_context_acknowledges_runtime_target_and_logs_transition() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "signal hook test",
            "",
            project,
            Some("claude"),
            Some("hook-sess"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
            session_service::join_session(
                "hook-sess",
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

        let signal = session_service::send_signal(
            "hook-sess",
            &worker_id,
            "inject_context",
            "follow the queued task",
            Some("review task-1"),
            &leader_id,
            project,
        )
        .expect("send signal");

        let context = NormalizedHookContext {
            event: NormalizedEvent::BeforeToolUse,
            session: SessionContext {
                session_id: "worker-session".into(),
                cwd: Some(project.to_path_buf()),
                transcript_path: None,
            },
            tool: None,
            agent: Some(AgentContext {
                agent_id: Some(worker_id.clone()),
                agent_type: Some("worker".into()),
                prompt: None,
                response: None,
            }),
            skill: SkillContext::inactive(),
            raw: RawPayload::new(json!({})),
        };

        let injected = collect_signal_context(HookAgent::Codex, &context).expect("signal text");
        assert!(injected.contains("follow the queued task"));

        let entries = session_storage::load_log_entries_legacy(project, "hook-sess").expect("entries");
        assert!(entries.into_iter().any(|entry| {
            matches!(
                entry.transition,
                SessionTransition::SignalAcknowledged {
                    signal_id,
                    agent_id,
                    result: runtime::signal::AckResult::Accepted,
                } if signal_id == signal.signal.signal_id && agent_id == worker_id
            )
        }));
    });
}

#[test]
fn collect_signal_context_marks_expired_signal_without_injecting_context() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "expired signal hook test",
            "",
            project,
            Some("claude"),
            Some("hook-expired-sess"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars(
            [("CODEX_SESSION_ID", Some("expired-worker-session"))],
            || {
                session_service::join_session(
                    "hook-expired-sess",
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

        let signal = session_service::send_signal(
            "hook-expired-sess",
            &worker_id,
            "inject_context",
            "stale context should not be delivered",
            Some("review task-1"),
            &leader_id,
            project,
        )
        .expect("send signal");

        let runtime = runtime::runtime_for_name("codex").expect("codex runtime");
        let signal_dir = runtime.signal_dir(project, "expired-worker-session");
        let expired_signal = runtime::signal::Signal {
            expires_at: "2000-01-01T00:00:00Z".into(),
            ..signal.signal.clone()
        };
        fs::write(
            signal_dir
                .join("pending")
                .join(format!("{}.json", expired_signal.signal_id)),
            serde_json::to_string_pretty(&expired_signal).expect("serialize expired signal"),
        )
        .expect("rewrite expired signal");

        let context = NormalizedHookContext {
            event: NormalizedEvent::BeforeToolUse,
            session: SessionContext {
                session_id: "expired-worker-session".into(),
                cwd: Some(project.to_path_buf()),
                transcript_path: None,
            },
            tool: None,
            agent: Some(AgentContext {
                agent_id: Some(worker_id.clone()),
                agent_type: Some("worker".into()),
                prompt: None,
                response: None,
            }),
            skill: SkillContext::inactive(),
            raw: RawPayload::new(json!({})),
        };

        let injected = collect_signal_context(HookAgent::Codex, &context);
        assert!(injected.is_none());

        let acks = runtime::signal::read_acknowledgments(&signal_dir).expect("acknowledgments");
        assert_eq!(acks.len(), 1);
        assert_eq!(acks[0].result, runtime::signal::AckResult::Expired);

        let entries =
            session_storage::load_log_entries_legacy(project, "hook-expired-sess").expect("entries");
        assert!(entries.into_iter().any(|entry| {
            matches!(
                entry.transition,
                SessionTransition::SignalAcknowledged {
                    signal_id,
                    agent_id,
                    result: runtime::signal::AckResult::Expired,
                } if signal_id == signal.signal.signal_id && agent_id == worker_id
            )
        }));
    });
}
