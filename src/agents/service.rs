use std::env;
use std::path::{Path, PathBuf};

use harness_kernel::errors::{CliError, CliErrorKind};
use harness_kernel::hooks::context::NormalizedHookContext;
use harness_protocol::agent::HookAgent;
use harness_protocol::session_resolution::{self, resolve_context_cwd};

use super::storage;

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

#[cfg(test)]
mod tests;
