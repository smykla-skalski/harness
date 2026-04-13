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
        signal_tui_readiness_if_managed();
        session_service::restore_compact_handoff(&project_dir)
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "session-start join error: {error}"
        )))
    })?
}

/// When running inside a daemon-managed TUI process, signal the daemon that
/// this agent is ready to accept input. The `HARNESS_AGENT_TUI_ID` env var is
/// set by the daemon at spawn time; its presence identifies a managed TUI.
fn signal_tui_readiness_if_managed() {
    let Ok(tui_id) = env::var("HARNESS_AGENT_TUI_ID") else {
        return;
    };
    if tui_id.is_empty() {
        return;
    }
    signal_tui_readiness(&tui_id);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn signal_tui_readiness(tui_id: &str) {
    use crate::daemon::client::DaemonClient;

    let Some(client) = DaemonClient::try_connect() else {
        tracing::debug!(tui_id = %tui_id, "no daemon client for TUI readiness signal");
        return;
    };
    match client.signal_tui_ready(tui_id) {
        Ok(_) => tracing::info!(tui_id = %tui_id, "TUI readiness signaled to daemon"),
        Err(error) => tracing::warn!(%error, tui_id = %tui_id, "failed to signal TUI readiness"),
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
mod tests {
    use std::path::Path;

    use serde_json::json;

    use super::*;
    use crate::agents::runtime::signal::{
        DeliveryConfig, Signal, SignalPayload, SignalPriority, read_pending_signals,
    };

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempfile::tempdir().expect("tempdir");
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
                std::fs::create_dir_all(&project).expect("create project directory");
                test_fn(&project);
            },
        );
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
}
