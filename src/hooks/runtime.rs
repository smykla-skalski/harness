use std::path::{Path, PathBuf};

use crate::agents::runtime;
use crate::agents::service::record_hook_event;
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as session_service;
use crate::workspace::utc_now;
use tracing::callsite::Identifier as CallsiteIdentifier;

use super::adapters::{HookAgent, adapter_for};
use super::application::{GuardContext, prepare_normalized_context};
use super::protocol::context::NormalizedEvent;
use super::protocol::hook_result::HookResult;
use super::protocol::result::NormalizedHookResult;
use super::registry::{Hook, HookEngine};
use super::{HookCommand, HookOutcome, HookType};

pub(crate) fn hook_runtime_result(hook: &dyn Hook, code: &str, message: &str) -> HookResult {
    if hook.hook_type().is_guard() {
        HookResult::deny(code, message)
    } else {
        HookResult::warn(code, message)
    }
}

pub(crate) fn dispatch_by_skill<RunnerFn, CreateFn>(
    ctx: &GuardContext,
    runner: RunnerFn,
    create: CreateFn,
) -> Result<HookResult, CliError>
where
    RunnerFn: FnOnce(&GuardContext) -> Result<HookResult, CliError>,
    CreateFn: FnOnce(&GuardContext) -> Result<HookResult, CliError>,
{
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_create() {
        return create(ctx);
    }
    runner(ctx)
}

pub(crate) fn dispatch_outcome_by_skill<RunnerFn, CreateFn>(
    ctx: &GuardContext,
    runner: RunnerFn,
    create: CreateFn,
) -> Result<HookOutcome, CliError>
where
    RunnerFn: FnOnce(&GuardContext) -> Result<HookOutcome, CliError>,
    CreateFn: FnOnce(&GuardContext) -> Result<HookOutcome, CliError>,
{
    if !ctx.skill_active {
        return Ok(HookOutcome::allow());
    }
    if ctx.is_suite_create() {
        return create(ctx);
    }
    runner(ctx)
}

fn format_hook_error_detail(hook: &dyn Hook, error: &CliError) -> String {
    let mut parts = vec![format!("`{}` failed internally: {error}", hook.name())];
    if let Some(hint) = error.hint() {
        parts.push(format!("Hint: {hint}"));
    }
    if let Some(details) = error.details() {
        parts.push(format!("Details: {details}"));
    }
    parts.join(" ")
}

fn default_event_for_hook(hook_type: HookType) -> NormalizedEvent {
    match hook_type {
        HookType::PreToolUse => NormalizedEvent::BeforeToolUse,
        HookType::PostToolUse => NormalizedEvent::AfterToolUse,
        HookType::PostToolUseFailure => NormalizedEvent::AfterToolUseFailure,
        HookType::SubagentStart => NormalizedEvent::SubagentStart,
        HookType::SubagentStop => NormalizedEvent::SubagentStop,
        HookType::Blocking => NormalizedEvent::AgentStop,
    }
}

fn default_event_for_command(hook: &HookCommand) -> NormalizedEvent {
    match hook {
        HookCommand::AuditTurn(_) => NormalizedEvent::Notification,
        _ => default_event_for_hook(hook.hook_type()),
    }
}

fn should_record_hook_event(hook: &HookCommand) -> bool {
    matches!(
        hook,
        HookCommand::ToolGuard
            | HookCommand::GuardStop
            | HookCommand::ToolResult
            | HookCommand::AuditTurn(_)
            | HookCommand::ToolFailure
            | HookCommand::ContextAgent
            | HookCommand::ValidateAgent
    )
}

fn render_runtime_error(
    agent: HookAgent,
    hook: &dyn Hook,
    event: &NormalizedEvent,
    code: &str,
    message: &str,
) -> i32 {
    let result = NormalizedHookResult::from_hook_result(hook_runtime_result(hook, code, message));
    let rendered = adapter_for(agent).render_output(&result, event);
    if !rendered.stdout.is_empty() {
        print!("{}", rendered.stdout);
    }
    rendered.exit_code
}

fn read_stdin_bytes() -> Result<Vec<u8>, CliError> {
    use std::io::{self, Read};

    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes).map_err(|error| {
        CliError::from(CliErrorKind::hook_payload_invalid(format!(
            "failed to read stdin: {error}"
        )))
    })?;
    Ok(bytes)
}

fn read_hook_input_bytes(hook: &HookCommand) -> Result<Vec<u8>, CliError> {
    if let Some(payload) = hook.inline_payload() {
        return Ok(payload.as_bytes().to_vec());
    }
    read_stdin_bytes()
}

/// Execute a hook command through the layered adapter/engine stack.
#[must_use]
pub fn run_hook_command(agent: HookAgent, skill: &str, hook: &HookCommand) -> i32 {
    let hook_impl = hook.hook();
    let hook_name = hook.name();
    let event = default_event_for_command(hook);
    let raw = match read_hook_input_bytes(hook) {
        Ok(raw) => raw,
        Err(error) => {
            let message = format!("`{hook_name}` received invalid hook payload: {error}");
            return render_runtime_error(agent, hook_impl, &event, "KSH001", &message);
        }
    };

    let adapter = adapter_for(agent);
    let normalized = match adapter.parse_input(&raw) {
        Ok(context) => prepare_normalized_context(context, skill, event),
        Err(error) => {
            let message = format!("`{hook_name}` received invalid hook payload: {error}");
            return render_runtime_error(agent, hook_impl, &event, "KSH001", &message);
        }
    };
    let normalized_for_record = normalized.clone();
    let render_event = normalized.event.clone();

    let result = match HookEngine::execute(hook_impl, normalized) {
        Ok(result) => result,
        Err(error) => {
            let detail = format_hook_error_detail(hook_impl, &error);
            NormalizedHookResult::from_hook_result(hook_runtime_result(
                hook_impl, "KSH002", &detail,
            ))
        }
    };

    let result = inject_pending_signals(agent, &normalized_for_record, result);

    if should_record_hook_event(hook)
        && let Err(error) =
            record_hook_event(agent, skill, hook_name, &normalized_for_record, &result)
    {
        let message = format!("`{hook_name}` failed to record agent event: {error}");
        return render_runtime_error(agent, hook_impl, &render_event, "KSH003", &message);
    }

    let rendered = adapter.render_output(&result, &render_event);
    if !rendered.stdout.is_empty() {
        print!("{}", rendered.stdout);
    }
    rendered.exit_code
}

/// Check for pending signals on `BeforeToolUse` events and inject context.
///
/// Non-blocking and failure-tolerant: signal delivery failure is logged but
/// never breaks the hook.
fn inject_pending_signals(
    agent: HookAgent,
    context: &super::protocol::context::NormalizedHookContext,
    mut result: NormalizedHookResult,
) -> NormalizedHookResult {
    if !matches!(context.event, NormalizedEvent::BeforeToolUse) {
        return result;
    }
    if let Some(text) = collect_signal_context(agent, context) {
        result.additional_context = Some(match result.additional_context {
            Some(existing) => format!("{existing}\n{text}"),
            None => text,
        });
    }
    result
}

fn collect_signal_context(
    agent: HookAgent,
    context: &super::protocol::context::NormalizedHookContext,
) -> Option<String> {
    let runtime_session_id = &context.session.session_id;
    if runtime_session_id.trim().is_empty() {
        return None;
    }
    let project_dir = context
        .session
        .cwd
        .as_deref()
        .unwrap_or_else(|| Path::new("."));

    let agent_runtime = runtime::runtime_for(agent);
    let resolved_session = resolve_signal_session(agent_runtime, project_dir, runtime_session_id);
    let (signal_dir, signals) = find_pending_signals(
        agent_runtime,
        project_dir,
        runtime_session_id,
        resolved_session.as_ref(),
    )?;
    let ids = derive_signal_ids(agent_runtime, runtime_session_id, resolved_session.as_ref());
    let now = utc_now();
    let lines: Vec<String> = signals
        .iter()
        .map(|signal| {
            acknowledge_signal(&signal_dir, signal, &ids, project_dir, &now);
            format!("[signal:{}] {}", signal.command, signal.payload.message)
        })
        .collect();
    Some(lines.join("\n"))
}

struct SignalIdentities {
    runtime_session: String,
    orchestration_session: String,
    agent: String,
}

fn derive_signal_ids(
    agent_runtime: &dyn runtime::AgentRuntime,
    runtime_session_id: &str,
    resolved: Option<&session_service::ResolvedRuntimeSessionAgent>,
) -> SignalIdentities {
    SignalIdentities {
        runtime_session: runtime_session_id.to_string(),
        orchestration_session: resolved.map_or_else(
            || runtime_session_id.to_string(),
            |r| r.orchestration_session_id.clone(),
        ),
        agent: resolved.map_or_else(|| agent_runtime.name().to_string(), |r| r.agent_id.clone()),
    }
}

fn resolve_signal_session(
    agent_runtime: &dyn runtime::AgentRuntime,
    project_dir: &Path,
    runtime_session_id: &str,
) -> Option<session_service::ResolvedRuntimeSessionAgent> {
    let result = session_service::resolve_session_agent_for_runtime_session(
        project_dir,
        agent_runtime.name(),
        runtime_session_id,
    );
    match result {
        Ok(resolved) => resolved,
        Err(error) => {
            warn_formatted(&format!(
                "failed to resolve runtime session for signal pickup: {error} \
                 (runtime={}, session={runtime_session_id})",
                agent_runtime.name(),
            ));
            None
        }
    }
}

fn find_pending_signals(
    agent_runtime: &dyn runtime::AgentRuntime,
    project_dir: &Path,
    runtime_session_id: &str,
    resolved_session: Option<&session_service::ResolvedRuntimeSessionAgent>,
) -> Option<(PathBuf, Vec<runtime::signal::Signal>)> {
    let orchestration_id = resolved_session.map_or(runtime_session_id, |resolved| {
        resolved.orchestration_session_id.as_str()
    });
    let signal_sources = runtime::signal_session_keys(orchestration_id, Some(runtime_session_id));
    let runtime_name = agent_runtime.name();
    signal_sources.into_iter().find_map(|signal_session_id| {
        let signal_dir = agent_runtime.signal_dir(project_dir, &signal_session_id);
        read_signals_from_dir(&signal_dir, runtime_name, &signal_session_id)
    })
}

fn read_signals_from_dir(
    signal_dir: &Path,
    runtime_name: &str,
    signal_session_id: &str,
) -> Option<(PathBuf, Vec<runtime::signal::Signal>)> {
    match runtime::signal::read_pending_signals(signal_dir) {
        Ok(list) if !list.is_empty() => Some((signal_dir.to_path_buf(), list)),
        Ok(_) => None,
        Err(error) => {
            warn_formatted(&format!(
                "failed to read pending signals: {error} (runtime={runtime_name}, session={signal_session_id})"
            ));
            None
        }
    }
}

fn acknowledge_signal(
    signal_dir: &Path,
    signal: &runtime::signal::Signal,
    ids: &SignalIdentities,
    project_dir: &Path,
    now: &str,
) {
    let ack = runtime::signal::SignalAck {
        signal_id: signal.signal_id.clone(),
        acknowledged_at: now.to_string(),
        result: runtime::signal::AckResult::Accepted,
        agent: ids.runtime_session.clone(),
        session_id: ids.orchestration_session.clone(),
        details: None,
    };
    if let Err(error) = runtime::signal::acknowledge_signal(signal_dir, &ack) {
        warn_formatted(&format!(
            "failed to acknowledge signal {}: {error} (session={})",
            signal.signal_id, ids.runtime_session,
        ));
        return;
    }
    record_signal_ack_in_session(
        &ids.orchestration_session,
        &ids.agent,
        &signal.signal_id,
        ack.result,
        project_dir,
    );
}

fn record_signal_ack_in_session(
    orchestration_session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: runtime::signal::AckResult,
    project_dir: &Path,
) {
    if let Err(error) = session_service::record_signal_acknowledgment(
        orchestration_session_id,
        agent_id,
        signal_id,
        result,
        project_dir,
    ) {
        warn_formatted(&format!(
            "failed to persist signal acknowledgment {signal_id}: {error} (agent={agent_id})"
        ));
    }
}

/// Emit a warning-level tracing event from a pre-formatted string.
///
/// Uses `tracing::Event::dispatch` directly because the `tracing::warn!`
/// macro expansion generates cognitive complexity 8 in clippy's analysis,
/// which exceeds the pedantic threshold of 7. This function achieves the
/// same result through the public tracing API without the macro.
fn warn_formatted(message: &str) {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "warn",
        "harness::hooks::runtime",
        Level::WARN,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, CallsiteIdentifier(&CALLSITE)),
        Kind::EVENT,
    );

    let values: &[Option<&dyn Value>] = &[Some(&message)];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::Path;

    use fs_err as fs;
    use harness_testkit::with_isolated_harness_env;
    use serde_json::json;
    use tempfile::tempdir;

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
            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                    session_service::join_session(
                        "hook-sess",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
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

            let entries = session_storage::load_log_entries(project, "hook-sess").expect("entries");
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
}
