use std::path::{Path, PathBuf};
use std::time::Instant;

use tracing::field::display;

use crate::agents::runtime;
use crate::agents::service::record_hook_event;
use crate::session::service as session_service;
use crate::telemetry::{current_trace_id, record_hook_metrics};

use super::super::adapters::{HookAgent, adapter_for};
use super::super::application::prepare_normalized_context;
use super::super::protocol::context::{NormalizedEvent, NormalizedHookContext};
use super::super::protocol::result::NormalizedHookResult;
use super::super::registry::{Hook, HookEngine};
use super::{HookCommand, hook_runtime_result};

pub(super) struct HookRunMetadata<'a> {
    pub(super) agent: HookAgent,
    pub(super) skill: &'a str,
    pub(super) hook: &'a HookCommand,
    pub(super) hook_impl: &'a dyn Hook,
    pub(super) hook_name: &'a str,
    pub(super) span: &'a tracing::Span,
    pub(super) started_at: Instant,
}

pub(super) struct HookExecution {
    pub(super) normalized_for_record: NormalizedHookContext,
    pub(super) render_event: NormalizedEvent,
    pub(super) render_event_name: String,
    pub(super) result: NormalizedHookResult,
}

pub(super) fn finish_hook_observation(
    span: &tracing::Span,
    hook_name: &str,
    event_name: &str,
    outcome: &str,
    started_at: Instant,
) {
    let duration_ms = u64::try_from(started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
    span.record("outcome", display(outcome));
    span.record("duration_ms", display(duration_ms));
    record_hook_metrics(hook_name, event_name, outcome, duration_ms);
    tracing::info!(
        hook_name = hook_name,
        event = event_name,
        outcome = outcome,
        duration_ms = duration_ms,
        "hook command finished"
    );
}

pub(super) fn read_hook_payload(
    metadata: &HookRunMetadata<'_>,
    event: &NormalizedEvent,
) -> Result<Vec<u8>, i32> {
    let _read_span = tracing::debug_span!("harness.hook.read_input").entered();
    super::read_hook_input_bytes(metadata.hook).map_err(|error| {
        let message = format!(
            "`{}` received invalid hook payload: {error}",
            metadata.hook_name
        );
        finish_hook_observation(
            metadata.span,
            metadata.hook_name,
            &format!("{event:?}"),
            "invalid-input",
            metadata.started_at,
        );
        super::render_runtime_error(
            metadata.agent,
            metadata.hook_impl,
            event,
            "KSH001",
            &message,
        )
    })
}

fn normalize_hook_payload(
    metadata: &HookRunMetadata<'_>,
    event: NormalizedEvent,
    raw: &[u8],
) -> Result<NormalizedHookContext, i32> {
    let adapter = adapter_for(metadata.agent);
    match adapter.parse_input(raw) {
        Ok(context) => {
            let _normalize_span = tracing::debug_span!("harness.hook.normalize").entered();
            Ok(prepare_normalized_context(context, metadata.skill, event))
        }
        Err(error) => {
            let message = format!(
                "`{}` received invalid hook payload: {error}",
                metadata.hook_name
            );
            finish_hook_observation(
                metadata.span,
                metadata.hook_name,
                &format!("{event:?}"),
                "invalid-input",
                metadata.started_at,
            );
            Err(super::render_runtime_error(
                metadata.agent,
                metadata.hook_impl,
                &event,
                "KSH001",
                &message,
            ))
        }
    }
}

pub(super) fn record_hook_context_fields(
    span: &tracing::Span,
    event_name: &str,
    context: &NormalizedHookContext,
) {
    span.record("event", display(event_name));
    if !context.session.session_id.trim().is_empty() {
        span.record("runtime_session_id", display(&context.session.session_id));
    }
}

pub(super) fn execute_hook_with_observability(
    hook_impl: &dyn Hook,
    normalized: NormalizedHookContext,
) -> NormalizedHookResult {
    let _engine_span = tracing::debug_span!("harness.hook.execute_engine").entered();
    let execution = HookEngine::execute(hook_impl, normalized);
    match execution {
        Ok(result) => result,
        Err(error) => {
            let detail = super::format_hook_error_detail(hook_impl, &error);
            NormalizedHookResult::from_hook_result(hook_runtime_result(
                hook_impl, "KSH002", &detail,
            ))
        }
    }
}

pub(super) fn prepare_hook_execution(
    metadata: &HookRunMetadata<'_>,
    event: NormalizedEvent,
    raw: &[u8],
) -> Result<HookExecution, i32> {
    let normalized = normalize_hook_payload(metadata, event, raw)?;
    let normalized_for_record = normalized.clone();
    let render_event = normalized.event.clone();
    let render_event_name = format!("{render_event:?}");
    record_hook_context_fields(metadata.span, &render_event_name, &normalized_for_record);

    let result = execute_hook_with_observability(metadata.hook_impl, normalized);
    let result = {
        let _signal_span = tracing::debug_span!("harness.hook.inject_pending_signals").entered();
        super::inject_pending_signals(metadata.agent, &normalized_for_record, result)
    };

    Ok(HookExecution {
        normalized_for_record,
        render_event,
        render_event_name,
        result,
    })
}

pub(super) fn record_hook_event_failure(
    metadata: &HookRunMetadata<'_>,
    execution: &HookExecution,
) -> Option<i32> {
    if !super::should_record_hook_event(metadata.hook) {
        return None;
    }

    let _record_span = tracing::debug_span!("harness.hook.record_event").entered();
    if let Err(error) = record_hook_event(
        metadata.agent,
        metadata.skill,
        metadata.hook_name,
        &execution.normalized_for_record,
        &execution.result,
    ) {
        let message = format!(
            "`{}` failed to record agent event: {error}",
            metadata.hook_name
        );
        finish_hook_observation(
            metadata.span,
            metadata.hook_name,
            &execution.render_event_name,
            "record-error",
            metadata.started_at,
        );
        return Some(super::render_runtime_error(
            metadata.agent,
            metadata.hook.hook(),
            &execution.render_event,
            "KSH003",
            &message,
        ));
    }
    None
}

pub(super) fn record_trace_id(span: &tracing::Span) {
    if let Some(trace_id) = current_trace_id() {
        span.record("trace_id", display(trace_id));
    }
}

pub(super) fn project_dir_for_signal_context(context: &NormalizedHookContext) -> &Path {
    context
        .session
        .cwd
        .as_deref()
        .unwrap_or_else(|| Path::new("."))
}

pub(super) fn resolve_signal_session_with_trace(
    agent_runtime: &dyn runtime::AgentRuntime,
    project_dir: &Path,
    runtime_session_id: &str,
) -> Option<session_service::ResolvedRuntimeSessionAgent> {
    let _resolve_span = tracing::debug_span!(
        "harness.hook.resolve_signal_session",
        runtime = agent_runtime.name(),
        runtime_session_id = runtime_session_id
    )
    .entered();
    super::resolve_signal_session(agent_runtime, project_dir, runtime_session_id)
}

pub(super) fn find_pending_signals_with_trace(
    agent_runtime: &dyn runtime::AgentRuntime,
    project_dir: &Path,
    runtime_session_id: &str,
    resolved_session: Option<&session_service::ResolvedRuntimeSessionAgent>,
) -> Option<(PathBuf, Vec<runtime::signal::Signal>)> {
    let _find_span = tracing::debug_span!(
        "harness.hook.find_pending_signals",
        runtime = agent_runtime.name(),
        runtime_session_id = runtime_session_id
    )
    .entered();
    super::find_pending_signals(
        agent_runtime,
        project_dir,
        runtime_session_id,
        resolved_session,
    )
}

pub(super) fn acknowledged_signal_lines(
    signal_dir: &Path,
    signals: &[runtime::signal::Signal],
    ids: &super::SignalIdentities,
    project_dir: &Path,
    now: &str,
) -> Vec<String> {
    signals
        .iter()
        .filter_map(|signal| {
            let _ack_span = tracing::debug_span!(
                "harness.hook.acknowledge_signal",
                signal_id = %signal.signal_id,
                signal_command = %signal.command
            )
            .entered();
            let result = super::acknowledge_signal(signal_dir, signal, ids, project_dir, now);
            (result != runtime::signal::AckResult::Expired)
                .then(|| format!("[signal:{}] {}", signal.command, signal.payload.message))
        })
        .collect()
}
