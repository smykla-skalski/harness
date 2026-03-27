use crate::agents::service::record_hook_event;
use crate::errors::{CliError, CliErrorKind};

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
        HookCommand::GuardBash
            | HookCommand::GuardWrite
            | HookCommand::GuardQuestion
            | HookCommand::GuardStop
            | HookCommand::Audit
            | HookCommand::AuditTurn(_)
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
