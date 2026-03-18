use std::env;
use std::path::PathBuf;
use std::sync::Arc;

use crate::infra::blocks::BlockRegistry;
use crate::run::context::{RunAggregate, RunContext, RunRepository};
use crate::errors::CliError;
use crate::run::resolve::resolve_run_directory;
use crate::run::services::RunServices;

pub use crate::run::args::RunDirArgs;

/// Uniform command execution trait.
///
/// Every command's Args struct implements this so dispatch can call
/// `.execute(&ctx)` without knowing the concrete type.
pub trait Execute {
    /// Run the command, returning an exit code on success.
    ///
    /// # Errors
    /// Returns `CliError` when the command fails.
    fn execute(&self, context: &CommandContext) -> Result<i32, CliError>;
}

/// Shared runtime context for command execution.
///
/// Carries the active block registry so command handlers and domain services
/// can resolve their dependencies from one place instead of constructing
/// concrete adapters ad hoc.
#[derive(Clone, Debug)]
pub struct CommandContext {
    blocks: Arc<BlockRegistry>,
}

impl CommandContext {
    #[must_use]
    pub fn production() -> Self {
        Self {
            blocks: Arc::new(BlockRegistry::production()),
        }
    }

    #[must_use]
    pub fn blocks(&self) -> &BlockRegistry {
        self.blocks.as_ref()
    }

    /// Resolve a run directory and build the domain service layer in one step
    /// using this command's shared block registry.
    ///
    /// # Errors
    /// Returns `CliError` when the run directory cannot be resolved or loaded.
    pub fn resolve_run_services(&self, args: &RunDirArgs) -> Result<RunServices, CliError> {
        RunServices::from_context_with_blocks(resolve_run_context(args)?, self.blocks.clone())
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Resolve the repository root from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_repo_root(raw: Option<&str>) -> PathBuf {
    raw.map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    )
}

/// Resolve a run directory from CLI arguments.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved.
pub(crate) fn resolve_run_dir(args: &RunDirArgs) -> Result<PathBuf, CliError> {
    resolve_run_directory(
        args.run_dir.as_deref(),
        args.run_id.as_deref(),
        args.run_root.as_deref(),
    )
    .map(|r| r.run_dir)
}

/// Resolve a project directory from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_project_dir(raw: Option<&str>) -> PathBuf {
    raw.filter(|s| !s.is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    )
}

/// Resolve a run directory and load its context in one step.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved or its
/// context cannot be loaded.
pub(crate) fn resolve_run_context(args: &RunDirArgs) -> Result<RunContext, CliError> {
    resolve_run_aggregate(args)
}

/// Resolve a run directory and build the domain service layer in one step.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved or loaded.
pub(crate) fn resolve_run_services(args: &RunDirArgs) -> Result<RunServices, CliError> {
    CommandContext::production().resolve_run_services(args)
}

/// Resolve a run directory and load its aggregate in one step.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved or its
/// aggregate cannot be loaded.
pub(crate) fn resolve_run_aggregate(args: &RunDirArgs) -> Result<RunAggregate, CliError> {
    let run_dir = resolve_run_dir(args)?;
    let repo = RunRepository;
    repo.load(&run_dir)
}
