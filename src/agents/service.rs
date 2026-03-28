use std::env;
use std::path::{Path, PathBuf};

use tokio::task;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::{HookAgent, adapter_for};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::infra::exec::RUNTIME;
use crate::setup::services::session as session_service;
use crate::workspace::utc_now;

use super::storage;

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
        session_service::restore_compact_handoff(&project_dir)
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "session-start join error: {error}"
        )))
    })?
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
            let session_id = if context.session.session_id.trim().is_empty() {
                storage::current_session_id(&project_dir, agent)?
                    .unwrap_or_else(|| default_session_id(agent))
            } else {
                context.session.session_id.clone()
            };
            if matches!(context.event, NormalizedEvent::SessionStart) {
                storage::set_current_session_id(&project_dir, agent, &session_id)?;
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
        .clone()
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

/// Resolve the effective session ID for a hook or lifecycle event.
///
/// # Errors
/// Returns `CliError` when the existing session registry cannot be read.
pub fn resolve_or_create_session_id(
    agent: HookAgent,
    project_dir: &Path,
    session_id_hint: Option<&str>,
) -> Result<String, CliError> {
    if let Some(session_id) = session_id_hint.filter(|value| !value.trim().is_empty()) {
        return Ok(session_id.to_string());
    }
    if let Some(session_id) = session_id_from_env(agent) {
        return Ok(session_id);
    }
    if let Some(existing) = storage::current_session_id(project_dir, agent)? {
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
            HookAgent::OpenCode => "opencode",
        },
        utc_now().replace([':', '-'], "")
    )
}
