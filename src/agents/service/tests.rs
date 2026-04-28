use std::fs;
use std::path::{Path, PathBuf};

use harness_testkit::with_isolated_harness_env;
use serde_json::json;

use super::*;
use crate::agents::runtime::signal::{
    DeliveryConfig, Signal, SignalPayload, SignalPriority, read_pending_signals,
};
use crate::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::session::service as session_service;
use crate::session::types::{AgentStatus, SessionRole, SessionStatus};

fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("xdg data path")),
                ),
                ("CLAUDE_SESSION_ID", Some("agent-service-session")),
            ],
            || {
                let project = tmp.path().join("project");
                fs::create_dir_all(&project).expect("create project directory");
                test_fn(&project);
            },
        );
    });
}

fn with_temp_project_without_runtime_ids<F: FnOnce(&Path)>(project_name: &str, test_fn: F) {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("xdg data path")),
                ),
                ("CLAUDE_SESSION_ID", None),
                ("CODEX_SESSION_ID", None),
                ("GEMINI_SESSION_ID", None),
                ("HOME", Some(tmp.path().to_str().expect("home path"))),
            ],
            || {
                let project = tmp.path().join(project_name);
                fs::create_dir_all(&project).expect("create project directory");
                test_fn(&project);
            },
        );
    });
}

fn sample_signal() -> Signal {
    Signal {
        signal_id: "sig-preserve-001".into(),
        version: 1,
        created_at: "2026-03-28T12:00:00Z".into(),
        expires_at: "2026-03-28T12:05:00Z".into(),
        source_agent: "leader".into(),
        command: "inject_context".into(),
        priority: SignalPriority::Normal,
        payload: SignalPayload {
            message: "preserve pending signal".into(),
            action_hint: None,
            related_files: vec![],
            metadata: json!(null),
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: None,
        },
    }
}

#[test]
fn session_start_preserves_pending_signals() {
    with_temp_project(|project| {
        RUNTIME
            .block_on(session_start(
                HookAgent::Claude,
                project.to_path_buf(),
                Some("sess-preserve".to_string()),
            ))
            .expect("initial session start");

        let runtime = super::super::runtime::runtime_for(HookAgent::Claude);
        runtime
            .write_signal(project, "sess-preserve", &sample_signal())
            .expect("write pending signal");

        let signal_dir = runtime.signal_dir(project, "sess-preserve");
        assert_eq!(
            read_pending_signals(&signal_dir)
                .expect("read pending signals before restart")
                .len(),
            1,
        );

        RUNTIME
            .block_on(session_start(
                HookAgent::Claude,
                project.to_path_buf(),
                Some("sess-preserve".to_string()),
            ))
            .expect("resume session");

        assert_eq!(
            read_pending_signals(&signal_dir)
                .expect("read pending signals after restart")
                .len(),
            1,
            "session restart must not drop queued signals",
        );
    });
}

#[test]
fn session_start_returns_no_additional_context_without_compact_handoff() {
    with_temp_project(|project| {
        let has_context = RUNTIME
            .block_on(session_start(
                HookAgent::Claude,
                project.to_path_buf(),
                Some("sess-policy".to_string()),
            ))
            .expect("session start")
            .is_none();

        assert!(
            has_context,
            "session-start should stay silent when there is no compact handoff to restore"
        );
    });
}

#[test]
fn project_dir_for_context_unescapes_shell_escaped_cwd_when_original_path_is_missing() {
    with_temp_project_without_runtime_ids("project@team", |project| {
        let escaped = project.to_string_lossy().replace('@', "\\@");
        let context = NormalizedHookContext {
            event: NormalizedEvent::AgentStop,
            session: SessionContext {
                session_id: "gemini-runtime".into(),
                cwd: Some(PathBuf::from(escaped)),
                transcript_path: None,
            },
            tool: None,
            agent: None,
            skill: SkillContext::inactive(),
            raw: RawPayload::new(json!({})),
        };

        let resolved = project_dir_for_context(&context).expect("resolve project dir");
        assert_eq!(resolved, project);
    });
}

#[test]
fn record_hook_event_registers_late_managed_runtime_session() {
    with_temp_project_without_runtime_ids("project@team", |project| {
        let started = session_service::start_session(
            "late gemini runtime session id",
            "",
            project,
            Some("sess-gemini-late"),
        )
        .expect("start session");
        let session_id = started.session_id;
        let tui_id = "agent-tui-gemini-1";
        session_service::join_session(
            &session_id,
            SessionRole::Worker,
            "gemini",
            &[
                "agent-tui".into(),
                format!("agent-tui:{tui_id}"),
                "observe".into(),
            ],
            None,
            project,
            None,
        )
        .expect("join gemini worker");

        let before = session_service::session_status(&session_id, project).expect("status");
        let worker = before
            .agents
            .values()
            .find(|agent| agent.runtime == "gemini")
            .expect("gemini worker");
        assert!(
            worker.agent_session_id.is_none(),
            "join should reproduce the missing runtime session id"
        );

        let escaped = project.to_string_lossy().replace('@', "\\@");
        let context = NormalizedHookContext {
            event: NormalizedEvent::AgentStop,
            session: SessionContext {
                session_id: "gemini-runtime-2152464d".into(),
                cwd: Some(PathBuf::from(escaped)),
                transcript_path: None,
            },
            tool: None,
            agent: Some(AgentContext {
                agent_id: None,
                agent_type: Some("gemini".into()),
                prompt: Some("/harness:harness session join sess-gemini-late".into()),
                response: Some("stop".into()),
            }),
            skill: SkillContext::inactive(),
            raw: RawPayload::new(json!({
                "session_id": "gemini-runtime-2152464d",
                "cwd": project.to_string_lossy(),
            })),
        };

        temp_env::with_vars(
            [
                ("HARNESS_SESSION_ID", Some(session_id.as_str())),
                ("HARNESS_AGENT_TUI_ID", Some(tui_id)),
            ],
            || {
                record_hook_event(
                    HookAgent::Gemini,
                    "suite:run",
                    "guard-stop",
                    &context,
                    &NormalizedHookResult::allow(),
                )
                .expect("record hook event");
            },
        );

        let after = session_service::session_status(&session_id, project).expect("status");
        let worker = after
            .agents
            .values()
            .find(|agent| agent.runtime == "gemini")
            .expect("gemini worker");
        assert_eq!(
            worker.agent_session_id.as_deref(),
            Some("gemini-runtime-2152464d")
        );
        assert_eq!(
            storage::current_session_id(project, HookAgent::Gemini).expect("current session id"),
            Some("gemini-runtime-2152464d".into())
        );
    });
}

#[test]
fn record_hook_event_session_end_disconnects_managed_agent() {
    with_temp_project_without_runtime_ids("project-session-end", |project| {
        let started = session_service::start_session(
            "managed session end cleanup",
            "",
            project,
            Some("sess-managed-end"),
        )
        .expect("start session");
        let session_id = started.session_id;
        let tui_id = "agent-tui-claude-1";
        session_service::join_session(
            &session_id,
            SessionRole::Leader,
            "claude",
            &[
                "agent-tui".into(),
                format!("agent-tui:{tui_id}"),
                "observe".into(),
            ],
            Some("Managed leader"),
            project,
            None,
        )
        .expect("join leader");

        let context = NormalizedHookContext {
            event: NormalizedEvent::SessionEnd,
            session: SessionContext {
                session_id: "claude-runtime-session".into(),
                cwd: Some(project.to_path_buf()),
                transcript_path: None,
            },
            tool: None,
            agent: Some(AgentContext {
                agent_id: None,
                agent_type: Some("claude".into()),
                prompt: Some("managed leader exit".into()),
                response: Some("exit".into()),
            }),
            skill: SkillContext::inactive(),
            raw: RawPayload::new(json!({
                "session_id": "claude-runtime-session",
                "cwd": project.to_string_lossy(),
            })),
        };

        temp_env::with_vars(
            [
                ("HARNESS_SESSION_ID", Some(session_id.as_str())),
                ("HARNESS_AGENT_TUI_ID", Some(tui_id)),
            ],
            || {
                record_hook_event(
                    HookAgent::Claude,
                    "suite:run",
                    "guard-stop",
                    &context,
                    &NormalizedHookResult::allow(),
                )
                .expect("record session end");
            },
        );

        let updated = session_service::session_status(&session_id, project).expect("status");
        let leader_id = updated.leader_id.clone();
        let leader = updated
            .agents
            .values()
            .find(|agent| agent.runtime == "claude")
            .expect("claude leader");
        assert_eq!(
            leader.agent_session_id.as_deref(),
            Some("claude-runtime-session")
        );
        assert_eq!(leader.status, AgentStatus::Disconnected);
        assert_eq!(updated.status, SessionStatus::LeaderlessDegraded);
        assert!(
            leader_id.is_none(),
            "leader session end should clear leader id"
        );
        assert_eq!(updated.metrics.active_agent_count, 0);
        assert_eq!(
            storage::current_session_id(project, HookAgent::Claude).expect("current session id"),
            None
        );
    });
}
