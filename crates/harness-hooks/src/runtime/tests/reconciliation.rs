//! `record_hook_event` reconciliation tests: aligning the hook-observed
//! runtime session id with orchestration state.

use std::path::{Path, PathBuf};

use super::*;
use harness_agents::kind::DisconnectReason;
use harness_agents::storage;
use harness_session::types::{AgentStatus, SessionStatus};

fn with_temp_project_without_runtime_ids<F: FnOnce(&Path)>(project_name: &str, test_fn: F) {
    let tmp = tempdir().expect("tempdir");
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

#[test]
fn record_hook_event_registers_late_managed_runtime_session() {
    with_temp_project_without_runtime_ids("project@team", |project| {
        let started = session_service::start_session(
            "late gemini runtime session id",
            "",
            project,
            Some("bc9852b3-c89f-5cb2-a896-e59adffc8316"),
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
            event: NormalizedEvent::AfterToolUse,
            session: SessionContext {
                session_id: "gemini-runtime-2152464d".into(),
                cwd: Some(PathBuf::from(escaped)),
                transcript_path: None,
            },
            tool: None,
            agent: Some(AgentContext {
                agent_id: None,
                agent_type: Some("gemini".into()),
                prompt: Some("harness session join bc9852b3-c89f-5cb2-a896-e59adffc8316".into()),
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
                observation::record_hook_event(
                    HookAgent::Gemini,
                    "suite:run",
                    "tool-result",
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
            Some("2325f772-e3ff-5180-9210-795508785d7d"),
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
                observation::record_hook_event(
                    HookAgent::Claude,
                    "suite:run",
                    "session-stop",
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
        assert_eq!(
            leader.status,
            AgentStatus::disconnected(DisconnectReason::UserCancelled)
        );
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
