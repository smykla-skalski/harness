use std::env;
use std::path::{Path, PathBuf};

use tokio::task;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::{HookAgent, adapter_for};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::session::service as orchestration_service;
use crate::workspace::{compact, current_run_context_path, utc_now};

use super::storage;

/// Locate a canonical transcript for a runtime session across project ledgers.
///
/// # Errors
/// Returns [`CliError`] when the session is ambiguous across ledgers.
pub fn find_canonical_session(
    session_id: &str,
    project_hint: Option<&str>,
    agent_hint: Option<HookAgent>,
) -> Result<Option<PathBuf>, CliError> {
    storage::find_canonical_session(session_id, project_hint, agent_hint)
}

#[must_use]
pub fn project_context_root_from_session_path(path: &Path) -> Option<PathBuf> {
    storage::project_context_root_from_session_path(path)
}

/// Start tracking an agent runtime session and restore its compact handoff.
///
/// # Errors
/// Returns [`CliError`] when the blocking task cannot be joined, the session
/// cannot be resolved or persisted, or the compact handoff cannot be restored.
pub async fn session_start(
    agent: HookAgent,
    project_dir: PathBuf,
    session_id_hint: Option<String>,
) -> Result<Option<String>, CliError> {
    task::spawn_blocking(move || {
        bootstrap_project_wrapper(&project_dir);
        let session_id =
            resolve_or_create_session_id(agent, &project_dir, session_id_hint.as_deref())?;
        storage::set_current_session_id(&project_dir, agent, &session_id)?;
        storage::append_session_marker(&project_dir, agent, &session_id, "session_start")?;
        signal_managed_terminal_readiness_if_managed();
        restore_compact_handoff(&project_dir)
    })
    .await
    .map_err(join_error("session-start"))?
}

/// Stop tracking an agent runtime session and clear its current-run state.
///
/// # Errors
/// Returns [`CliError`] when the blocking task cannot be joined or session
/// markers and current-run state cannot be updated.
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
        clear_current_run_pointer()?;
        Ok(())
    })
    .await
    .map_err(join_error("session-stop"))?
}

/// Record a user prompt submission for an agent runtime session.
///
/// # Errors
/// Returns [`CliError`] when the payload cannot be parsed, the session cannot
/// be resolved or persisted, or the blocking task cannot be joined.
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
    .map_err(join_error("prompt-submit"))?
}

/// Record a normalized hook event and reconcile its managed runtime session.
///
/// # Errors
/// Returns [`CliError`] when the project directory is unavailable or session
/// state and hook event storage cannot be read or updated.
pub fn record_hook_event(
    agent: HookAgent,
    skill: &str,
    hook_name: &str,
    context: &NormalizedHookContext,
    result: &NormalizedHookResult,
) -> Result<(), CliError> {
    let project_dir = project_dir_for_context(context)?;
    let observed = observed_runtime_session_id(context);
    let previous = storage::current_session_id(&project_dir, agent)?;
    let session_id = observed.map_or_else(
        || {
            previous
                .clone()
                .unwrap_or_else(|| default_session_id(agent))
        },
        ToString::to_string,
    );
    if observed.is_some() {
        storage::set_current_session_id(&project_dir, agent, &session_id)?;
        reconcile_managed_runtime_session(&project_dir, agent, &session_id, previous.as_deref())?;
    }
    storage::append_hook_event(
        &project_dir,
        agent,
        &session_id,
        skill,
        hook_name,
        context,
        result,
    )?;
    disconnect_managed_runtime_session_if_ended(&project_dir, agent, context)?;
    if context.event == NormalizedEvent::SessionEnd {
        storage::clear_current_session_id(&project_dir, agent)?;
    }
    Ok(())
}

fn project_dir_for_context(context: &NormalizedHookContext) -> Result<PathBuf, CliError> {
    context
        .session
        .cwd
        .as_deref()
        .and_then(resolve_context_cwd)
        .or_else(|| env::current_dir().ok())
        .ok_or_else(|| {
            CliErrorKind::workflow_io("missing project directory for agent event".to_string())
                .into()
        })
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
    let Some(managed_agent_id) = trimmed_env("HARNESS_AGENT_TUI_ID") else {
        return Ok(());
    };
    let _ = orchestration_service::register_agent_runtime_session(
        &orchestration_session_id,
        adapter_for(agent).name(),
        &managed_agent_id,
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
    if !orchestration_service::session_agent_is_alive(
        &resolved.orchestration_session_id,
        &resolved.session_agent_id,
        project_dir,
    )? {
        return Ok(());
    }
    orchestration_service::leave_session(
        &resolved.orchestration_session_id,
        &resolved.session_agent_id,
        project_dir,
    )
}

fn bootstrap_project_wrapper(project_dir: &Path) {
    let path = env::var("PATH").unwrap_or_default();
    let _ = crate::setup::wrapper::main(project_dir, &path);
}

fn signal_managed_terminal_readiness_if_managed() {
    let Some(managed_agent_id) = trimmed_env("HARNESS_AGENT_TUI_ID") else {
        return;
    };
    match crate::session::daemon::signal_managed_terminal_ready(&managed_agent_id) {
        Some(Ok(())) => tracing::info!(
            managed_agent_id,
            "managed terminal readiness signaled to daemon"
        ),
        Some(Err(error)) => tracing::warn!(
            %error,
            managed_agent_id,
            "failed to signal managed terminal readiness"
        ),
        None => tracing::debug!(
            managed_agent_id,
            "no daemon client for managed terminal readiness signal"
        ),
    }
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
    while let Some(character) = chars.next() {
        if character == '\\'
            && let Some(next) = chars.peek().copied()
            && next != '\\'
            && next != '/'
        {
            unescaped.push(next);
            let _ = chars.next();
            changed = true;
            continue;
        }
        unescaped.push(character);
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
    hint: Option<&str>,
) -> Result<Option<String>, CliError> {
    if let Some(value) = hint.filter(|value| !value.trim().is_empty()) {
        return Ok(Some(value.to_string()));
    }
    if let Some(value) = session_id_from_env(agent) {
        return Ok(Some(value));
    }
    storage::current_session_id(project_dir, agent)
}

fn resolve_or_create_session_id(
    agent: HookAgent,
    project_dir: &Path,
    hint: Option<&str>,
) -> Result<String, CliError> {
    Ok(resolve_known_session_id(agent, project_dir, hint)?
        .unwrap_or_else(|| default_session_id(agent)))
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
        adapter_for(agent).name(),
        utc_now().replace([':', '-'], "")
    )
}

fn restore_compact_handoff(project_dir: &Path) -> Result<Option<String>, CliError> {
    let Some(handoff) = compact::pending_compact_handoff(project_dir)? else {
        return Ok(None);
    };
    let diverged = compact::verify_fingerprints(&handoff);
    let context = compact::render_hydration_context(&handoff, &diverged);
    let _ = compact::consume_compact_handoff(project_dir, handoff);
    Ok(Some(context))
}

fn clear_current_run_pointer() -> Result<(), CliError> {
    let path = current_run_context_path()?;
    match fs_err::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => {
            Err(CliErrorKind::workflow_io(format!("clear current run context: {error}")).into())
        }
    }
}

fn join_error(operation: &'static str) -> impl FnOnce(tokio::task::JoinError) -> CliError {
    move |error| CliErrorKind::workflow_io(format!("{operation} join error: {error}")).into()
}
