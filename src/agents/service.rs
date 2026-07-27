use std::env;
use std::path::{Path, PathBuf};

use tokio::task;

use crate::hooks::adapters::HookAgent;
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::infra::exec::RUNTIME;
use crate::session::service as orchestration_service;
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::session_resolution::{self, resolve_context_cwd, trimmed_env};

use super::storage;

/// Record a normalized hook event in the shared agent ledger.
///
/// # Errors
/// Returns `CliError` when the project directory cannot be resolved or the
/// shared ledger update fails.
pub fn record_hook_event(
    agent: HookAgent,
    skill: &str,
    hook_name: &str,
    context: &NormalizedHookContext,
    result: &NormalizedHookResult,
) -> Result<(), CliError> {
    let project_dir = project_dir_for_context(context)?;
    let skill_name = skill.to_string();
    let hook_name = hook_name.to_string();
    let context = context.clone();
    let result = result.clone();
    RUNTIME.block_on(async move {
        task::spawn_blocking(move || {
            let observed_session_id = observed_runtime_session_id(&context);
            let previous_session_id = storage::current_session_id(&project_dir, agent)?;
            let session_id = observed_session_id.map_or_else(
                || {
                    previous_session_id
                        .clone()
                        .unwrap_or_else(|| default_session_id(agent))
                },
                ToString::to_string,
            );
            if observed_session_id.is_some() {
                storage::set_current_session_id(&project_dir, agent, &session_id)?;
                reconcile_managed_runtime_session(
                    &project_dir,
                    agent,
                    &session_id,
                    previous_session_id.as_deref(),
                )?;
            }
            storage::append_hook_event(
                &project_dir,
                agent,
                &session_id,
                &skill_name,
                &hook_name,
                &context,
                &result,
            )?;
            disconnect_managed_runtime_session_if_ended(&project_dir, agent, &context)?;
            if matches!(context.event, NormalizedEvent::SessionEnd) {
                storage::clear_current_session_id(&project_dir, agent)?;
            }
            Ok(())
        })
        .await
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "agent event join error: {error}"
            )))
        })?
    })
}

/// Resolve the project directory associated with a normalized hook context.
///
/// # Errors
/// Returns `CliError` when neither the hook payload nor the process cwd provide
/// a usable project directory.
pub fn project_dir_for_context(context: &NormalizedHookContext) -> Result<PathBuf, CliError> {
    context
        .session
        .cwd
        .as_deref()
        .and_then(resolve_context_cwd)
        .or_else(|| env::current_dir().ok())
        .map_or_else(
            || {
                Err(CliErrorKind::workflow_io(
                    "missing project directory for agent event".to_string(),
                )
                .into())
            },
            Ok,
        )
}

fn observed_runtime_session_id(context: &NormalizedHookContext) -> Option<&str> {
    let session_id = context.session.session_id.trim();
    (!session_id.is_empty()).then_some(session_id)
}

fn reconcile_managed_runtime_session(
    project_dir: &Path,
    agent: HookAgent,
    runtime_session_id: &str,
    previous_session_id: Option<&str>,
) -> Result<(), CliError> {
    if previous_session_id == Some(runtime_session_id) {
        return Ok(());
    }
    let Some(orchestration_session_id) = trimmed_env("HARNESS_SESSION_ID") else {
        return Ok(());
    };
    let Some(tui_id) = trimmed_env("HARNESS_AGENT_TUI_ID") else {
        return Ok(());
    };
    let _ = orchestration_service::register_agent_runtime_session(
        &orchestration_session_id,
        agent_name(agent),
        &tui_id,
        runtime_session_id,
        project_dir,
    )?;
    Ok(())
}

fn disconnect_managed_runtime_session_if_ended(
    project_dir: &Path,
    agent: HookAgent,
    context: &NormalizedHookContext,
) -> Result<(), CliError> {
    if context.event != NormalizedEvent::SessionEnd {
        return Ok(());
    }
    let Some(runtime_session_id) = observed_runtime_session_id(context) else {
        return Ok(());
    };
    let Some(resolved) = orchestration_service::resolve_session_agent_for_runtime_session(
        project_dir,
        agent_name(agent),
        runtime_session_id,
    )?
    else {
        return Ok(());
    };
    let state =
        orchestration_service::session_status(&resolved.orchestration_session_id, project_dir)?;
    let Some(agent_state) = state.agents.get(&resolved.session_agent_id) else {
        return Ok(());
    };
    if !agent_state.status.is_alive() {
        return Ok(());
    }
    orchestration_service::leave_session(
        &resolved.orchestration_session_id,
        &resolved.session_agent_id,
        project_dir,
    )
}

/// Resolve a known session ID for a hook or lifecycle event.
///
/// # Errors
/// Returns `CliError` when the existing session registry cannot be read.
pub fn resolve_known_session_id(
    agent: HookAgent,
    project_dir: &Path,
    session_id_hint: Option<&str>,
) -> Result<Option<String>, CliError> {
    session_resolution::resolve_known_session_id(agent, session_id_hint, || {
        storage::current_session_id(project_dir, agent)
    })
}

// `AgentAdapter::name` returns this same string, but going through the hook
// adapter dispatch just to name a `HookAgent` variant would pull the hooks
// parsing layer into the ledger for data the enum already carries.
fn agent_name(agent: HookAgent) -> &'static str {
    match agent {
        HookAgent::Claude => "claude",
        HookAgent::Codex => "codex",
        HookAgent::Gemini => "gemini",
        HookAgent::Copilot => "copilot",
        HookAgent::Vibe => "vibe",
        HookAgent::OpenCode => "opencode",
    }
}

fn default_session_id(agent: HookAgent) -> String {
    format!("{}-{}", agent_name(agent), utc_now().replace([':', '-'], ""))
}

#[cfg(test)]
mod tests;
