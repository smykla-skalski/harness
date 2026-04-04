use std::env;
use std::path::PathBuf;

use crate::errors::CliError;
use crate::workspace::canonical_checkout_root;

/// Uniform command execution trait.
///
/// Every command's Args struct implements this so dispatch can call
/// `.execute(&ctx)` without knowing the concrete type.
pub trait Execute {
    /// Run the command, returning an exit code on success.
    ///
    /// # Errors
    /// Returns `CliError` when the command fails.
    fn execute(&self, context: &AppContext) -> Result<i32, CliError>;
}

/// Shared runtime context for command execution.
///
/// This remains a thin app-layer handle. Domain commands should route through
/// application boundaries instead of reaching into concrete adapters here.
#[derive(Clone, Debug, Default)]
pub struct AppContext;

impl AppContext {
    #[must_use]
    pub fn production() -> Self {
        Self
    }
}

/// Resolve the repository root from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_repo_root(raw: Option<&str>) -> PathBuf {
    raw.map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    )
}

/// Resolve a project directory from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_project_dir(raw: Option<&str>) -> PathBuf {
    let path = raw.filter(|s| !s.is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    );
    canonical_checkout_root(&path)
}
