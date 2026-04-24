use std::env;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use fs_err as fs;
use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::tempdir;
use tracing::field::{Field, Visit};
use tracing_subscriber::Layer;
use tracing_subscriber::layer::Context;
use tracing_subscriber::prelude::*;

use super::*;
use crate::hooks::protocol::context::{
    AgentContext, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::session::storage as session_storage;
use crate::session::types::{SessionRole, SessionState, SessionTransition};

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

fn with_locked_current_dir<F: FnOnce()>(dir: &Path, test_fn: F) {
    static CWD_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();
    let _guard = CWD_MUTEX
        .get_or_init(|| Mutex::new(()))
        .lock()
        .expect("cwd mutex");
    let old_dir = env::current_dir().expect("current dir");
    env::set_current_dir(dir).expect("set current dir");
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(test_fn));
    env::set_current_dir(old_dir).expect("restore current dir");
    if let Err(panic) = result {
        std::panic::resume_unwind(panic);
    }
}

fn start_active_session(project: &Path, session_id: &str, context: &str) -> SessionState {
    let state = session_service::start_session(context, "", project, Some(session_id))
        .expect("start session");
    session_service::join_session(
        &state.session_id,
        SessionRole::Leader,
        "claude",
        &[],
        Some("leader"),
        project,
        None,
    )
    .expect("join leader")
}

#[test]
fn prepare_hook_execution_canonicalizes_relative_cwd_for_signal_pickup() {
    with_temp_project(|project| {
        let state = start_active_session(project, "hook-runtime-sess", "signal runtime test");
        let leader_id = state.leader_id.expect("leader id");
        let joined =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("runtime-worker-session"))], || {
                session_service::join_session(
                    "hook-runtime-sess",
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

        session_service::send_signal(
            "hook-runtime-sess",
            &worker_id,
            "inject_context",
            "runtime path should receive queued context",
            Some("review task-1"),
            &leader_id,
            project,
        )
        .expect("send signal");

        with_locked_current_dir(project, || {
            let hook = HookCommand::ToolGuard;
            let span = tracing::info_span!("hook_runtime_test");
            let metadata = observation::HookRunMetadata {
                agent: HookAgent::Codex,
                skill: "",
                hook: &hook,
                hook_impl: hook.hook(),
                hook_name: hook.name(),
                span: &span,
                started_at: Instant::now(),
            };
            let raw = br#"{
                "session_id":"runtime-worker-session",
                "cwd":".",
                "hook_event_name":"PreToolUse",
                "tool_name":"Read",
                "tool_input":{"file_path":"Cargo.toml"}
            }"#;

            let execution = observation::prepare_hook_execution(
                &metadata,
                NormalizedEvent::BeforeToolUse,
                raw,
            )
            .expect("hook execution");

            assert_eq!(
                execution.normalized_for_record.session.cwd,
                Some(project.canonicalize().unwrap_or_else(|_| project.to_path_buf()))
            );
            assert!(
                execution
                    .result
                    .additional_context
                    .as_deref()
                    .is_some_and(|text| text.contains("runtime path should receive queued context"))
            );
        });
    });
}

#[test]
fn collect_signal_context_acknowledges_runtime_target_and_logs_transition() {
    with_temp_project(|project| {
        let state = start_active_session(project, "hook-sess", "signal hook test");
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

        let layout =
            session_storage::layout_from_project_dir(project, "hook-sess").expect("layout");
        let entries = session_storage::load_log_entries(&layout).expect("entries");
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

#[derive(Clone, Default)]
struct EventCaptureLayer {
    messages: Arc<Mutex<Vec<String>>>,
}

#[derive(Default)]
struct MessageVisitor {
    message: Option<String>,
}

impl Visit for MessageVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = Some(value.to_string());
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = Some(format!("{value:?}"));
        }
    }
}

impl<S> Layer<S> for EventCaptureLayer
where
    S: tracing::Subscriber,
{
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        if let Some(message) = visitor.message {
            self.messages.lock().expect("messages lock").push(message);
        }
    }
}

#[test]
fn finish_hook_observation_emits_completion_log() {
    let layer = EventCaptureLayer::default();
    let messages = Arc::clone(&layer.messages);
    let subscriber = tracing_subscriber::registry().with(layer);

    tracing::subscriber::with_default(subscriber, || {
        let span = tracing::info_span!("hook_runtime_test");
        let _guard = span.enter();
        observation::finish_hook_observation(
            &span,
            "tool-guard",
            "BeforeToolUse",
            "allow",
            Instant::now(),
        );
    });

    let messages = messages.lock().expect("messages lock");
    assert!(
        messages
            .iter()
            .any(|message| message.contains("hook command finished")),
        "expected hook completion log event, got {messages:?}"
    );
}

#[test]
fn collect_signal_context_marks_expired_signal_without_injecting_context() {
    with_temp_project(|project| {
        let state = start_active_session(project, "hook-expired-sess", "expired signal hook test");
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

        let layout =
            session_storage::layout_from_project_dir(project, "hook-expired-sess").expect("layout");
        let entries = session_storage::load_log_entries(&layout).expect("entries");
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
