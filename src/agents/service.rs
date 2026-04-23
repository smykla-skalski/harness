use std::env;
use std::path::{Path, PathBuf};

use tokio::task;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::{HookAgent, RenderedHookResponse, adapter_for};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::infra::exec::RUNTIME;
use crate::session::service as orchestration_service;
use crate::setup::services::session as session_service;
use crate::workspace::utc_now;

use super::{repo_policy, storage};

/// Start or resume the active agent session for a project.
///
/// # Errors
/// Returns `CliError` when the shared agent session ledger cannot be updated or
/// when restoring pending compact handoff state fails.
pub async fn session_start(
    agent: HookAgent,
    project_dir: PathBuf,
    session_id_hint: Option<String>,
) -> Result<Option<String>, CliError> {
    task::spawn_blocking(move || {
        session_service::bootstrap_project_wrapper(&project_dir);
        let session_id =
            resolve_or_create_session_id(agent, &project_dir, session_id_hint.as_deref())?;
        storage::set_current_session_id(&project_dir, agent, &session_id)?;
        storage::append_session_marker(&project_dir, agent, &session_id, "session_start")?;
        signal_managed_terminal_readiness_if_managed();
        let mut contexts = vec![repo_policy::session_start_context().to_string()];
        if let Some(handoff) = session_service::restore_compact_handoff(&project_dir)? {
            contexts.push(handoff);
        }
        Ok(Some(contexts.join("\n\n")))
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "session-start join error: {error}"
        )))
    })?
}

/// Render the repo-wide pre-tool policy response for an agent runtime.
#[must_use]
pub fn repo_policy_pre_tool_use(
    agent: HookAgent,
    raw_payload: &[u8],
) -> Option<RenderedHookResponse> {
    repo_policy::pre_tool_use_output(agent, raw_payload)
}

/// When running inside a daemon-managed TUI process, signal the daemon that
/// this agent is ready to accept input. The `HARNESS_AGENT_TUI_ID` env var is
/// set by the daemon at spawn time; its presence identifies a managed TUI.
fn signal_managed_terminal_readiness_if_managed() {
    let Ok(tui_id) = env::var("HARNESS_AGENT_TUI_ID") else {
        return;
    };
    if tui_id.is_empty() {
        return;
    }
    signal_managed_terminal_readiness(&tui_id);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn signal_managed_terminal_readiness(tui_id: &str) {
    use crate::daemon::client::DaemonClient;

    let Some(client) = DaemonClient::try_connect() else {
        tracing::debug!(tui_id = %tui_id, "no daemon client for managed terminal readiness signal");
        return;
    };
    match client.signal_managed_terminal_ready(tui_id) {
        Ok(()) => tracing::info!(tui_id = %tui_id, "managed terminal readiness signaled to daemon"),
        Err(error) => tracing::warn!(
            %error,
            tui_id = %tui_id,
            "failed to signal managed terminal readiness"
        ),
    }
}

/// Stop the active agent session for a project.
///
/// # Errors
/// Returns `CliError` when the shared agent session ledger cannot be updated or
/// the current run context cannot be cleaned up.
pub async fn session_stop(
    agent: HookAgent,
    project_dir: PathBuf,
    session_id_hint: Option<String>,
) -> Result<(), CliError> {
    task::spawn_blocking(move || {
        let session_id = session_id_hint
            .or_else(|| {
                storage::current_session_id(&project_dir, agent)
                    .ok()
                    .flatten()
            })
            .unwrap_or_else(|| default_session_id(agent));
        storage::append_session_marker(&project_dir, agent, &session_id, "session_stop")?;
        storage::clear_current_session_id(&project_dir, agent)?;
        session_service::cleanup_current_run_context()?;
        Ok(())
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "session-stop join error: {error}"
        )))
    })?
}

/// Record a prompt-submission event through the harness-owned agent ledger.
///
/// # Errors
/// Returns `CliError` when the inbound agent payload is malformed or the shared
/// agent storage cannot be updated.
pub async fn prompt_submit(
    agent: HookAgent,
    project_dir: PathBuf,
    session_id_hint: Option<String>,
    raw_payload: Vec<u8>,
) -> Result<(), CliError> {
    task::spawn_blocking(move || {
        let mut context = adapter_for(agent).parse_input(&raw_payload)?;
        context.event = NormalizedEvent::UserPromptSubmit;
        if context.session.cwd.is_none() {
            context.session.cwd = Some(project_dir.clone());
        }
        let session_id = if context.session.session_id.trim().is_empty() {
            resolve_or_create_session_id(agent, &project_dir, session_id_hint.as_deref())?
        } else {
            context.session.session_id.clone()
        };
        storage::set_current_session_id(&project_dir, agent, &session_id)?;
        storage::append_hook_event(
            &project_dir,
            agent,
            &session_id,
            "agents",
            "user-prompt-submit",
            &context,
            &NormalizedHookResult::allow(),
        )
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "prompt-submit join error: {error}"
        )))
    })?
}

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
        adapter_for(agent).name(),
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
        adapter_for(agent).name(),
        runtime_session_id,
    )?
    else {
        return Ok(());
    };
    let state =
        orchestration_service::session_status(&resolved.orchestration_session_id, project_dir)?;
    let Some(agent_state) = state.agents.get(&resolved.agent_id) else {
        return Ok(());
    };
    if !agent_state.status.is_alive() {
        return Ok(());
    }
    orchestration_service::leave_session(
        &resolved.orchestration_session_id,
        &resolved.agent_id,
        project_dir,
    )
}

fn trimmed_env(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn resolve_context_cwd(path: &Path) -> Option<PathBuf> {
    if path.is_dir() {
        return Some(path.to_path_buf());
    }
    shell_unescaped_path(path).filter(|candidate| candidate.is_dir())
}

fn shell_unescaped_path(path: &Path) -> Option<PathBuf> {
    let raw = path.to_str()?;
    let mut changed = false;
    let mut unescaped = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\\'
            && let Some(next) = chars.peek().copied()
            && next != '\\'
            && next != '/'
        {
            unescaped.push(next);
            let _ = chars.next();
            changed = true;
            continue;
        }
        unescaped.push(ch);
    }
    changed.then(|| PathBuf::from(unescaped))
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
    if let Some(session_id) = session_id_hint.filter(|value| !value.trim().is_empty()) {
        return Ok(Some(session_id.to_string()));
    }
    if let Some(session_id) = session_id_from_env(agent) {
        return Ok(Some(session_id));
    }
    storage::current_session_id(project_dir, agent)
}

/// Resolve the effective session ID for a hook or lifecycle event.
///
/// # Errors
/// Returns `CliError` when the existing session registry cannot be read.
pub fn resolve_or_create_session_id(
    agent: HookAgent,
    project_dir: &Path,
    session_id_hint: Option<&str>,
) -> Result<String, CliError> {
    if let Some(existing) = resolve_known_session_id(agent, project_dir, session_id_hint)? {
        return Ok(existing);
    }
    Ok(default_session_id(agent))
}

fn session_id_from_env(agent: HookAgent) -> Option<String> {
    let candidates = match agent {
        HookAgent::Claude => &["CLAUDE_SESSION_ID"][..],
        HookAgent::Codex => &["CODEX_SESSION_ID", "CODEX_THREAD_ID"][..],
        HookAgent::Gemini => &["GEMINI_SESSION_ID", "CLAUDE_SESSION_ID"][..],
        HookAgent::Copilot => &["COPILOT_SESSION_ID"][..],
        HookAgent::Vibe => &["VIBE_SESSION_ID"][..],
        HookAgent::OpenCode => &["OPENCODE_SESSION_ID"][..],
    };
    candidates
        .iter()
        .find_map(|name| env::var(name).ok().filter(|value| !value.trim().is_empty()))
}

fn default_session_id(agent: HookAgent) -> String {
    format!(
        "{}-{}",
        match agent {
            HookAgent::Claude => "claude",
            HookAgent::Codex => "codex",
            HookAgent::Gemini => "gemini",
            HookAgent::Copilot => "copilot",
            HookAgent::Vibe => "vibe",
            HookAgent::OpenCode => "opencode",
        },
        utc_now().replace([':', '-'], "")
    )
}

#[cfg(test)]
mod tests;
