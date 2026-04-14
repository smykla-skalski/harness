use super::{HookAgent, CliError, CliErrorKind, Path, SessionState, storage, SessionMetrics, runtime};

pub(crate) fn resolve_registered_runtime(runtime_name: &str) -> Option<HookAgent> {
    match runtime_name {
        "claude" => Some(HookAgent::Claude),
        "copilot" => Some(HookAgent::Copilot),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "vibe" => Some(HookAgent::Vibe),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

pub(crate) fn ensure_known_runtime(runtime_name: &str, message_prefix: &str) -> Result<(), CliError> {
    if resolve_registered_runtime(runtime_name).is_some() {
        Ok(())
    } else {
        Err(CliError::from(CliErrorKind::session_agent_conflict(
            format!("{message_prefix}, got '{runtime_name}'"),
        )))
    }
}

pub(crate) fn load_state_or_err(session_id: &str, project_dir: &Path) -> Result<SessionState, CliError> {
    storage::load_state(project_dir, session_id)?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
    })
}

pub(crate) fn refresh_session(state: &mut SessionState, now: &str) {
    state.updated_at = now.to_string();
    state.last_activity_at = Some(now.to_string());
    state.metrics = SessionMetrics::recalculate(state);
}

pub(crate) fn runtime_capabilities(runtime_name: &str) -> runtime::RuntimeCapabilities {
    runtime::runtime_for_name(runtime_name).map_or_else(
        || runtime::RuntimeCapabilities {
            runtime: runtime_name.to_string(),
            ..runtime::RuntimeCapabilities::default()
        },
        |agent_runtime| {
            let mut capabilities = agent_runtime.capabilities();
            capabilities.runtime = runtime_name.to_string();
            capabilities
        },
    )
}
