use std::env;
use std::path::PathBuf;

use crate::cli::{Command, RunDirArgs};
use crate::context::{RunContext, RunLookup};
use crate::errors::{CliError, CliErrorKind};
use crate::resolve::resolve_run_directory;

pub mod authoring;
pub mod run;
pub mod setup;

// ---------------------------------------------------------------------------
// Execute trait
// ---------------------------------------------------------------------------

/// Dispatch a parsed CLI command to its handler and return the process exit
/// code.
///
/// Every `Command` variant (except `Hook`, which is handled separately in
/// `cli.rs`) implements this trait so that `cli::run()` can call
/// `command.execute()` without knowing which handler it routes to.
///
/// # Errors
/// Returns `CliError` when the underlying command handler fails.
pub trait Execute {
    /// Run the command and return the exit code.
    ///
    /// # Errors
    /// Returns `CliError` on failure.
    fn execute(self) -> Result<i32, CliError>;
}

impl Execute for Command {
    #[allow(clippy::too_many_lines)]
    fn execute(self) -> Result<i32, CliError> {
        match self {
            // Hooks are handled before reaching Execute.
            Command::Hook { .. } => unreachable!("hooks are handled separately"),

            // --- setup ---
            Command::Init(args) => run::init_run(
                &args.suite,
                &args.run_id,
                &args.profile,
                args.repo_root.as_deref(),
                args.run_root.as_deref(),
            ),
            Command::Bootstrap { project_dir } => setup::bootstrap(project_dir.as_deref()),
            Command::Cluster(args) => setup::cluster(
                &args.mode,
                &args.cluster_name,
                &args.extra_cluster_names,
                args.repo_root.as_deref(),
                args.run_dir.as_deref(),
                &args.helm_setting,
                &args.restart_namespace,
            ),
            Command::Preflight {
                kubeconfig,
                repo_root,
                run_dir,
            } => run::preflight(kubeconfig.as_deref(), repo_root.as_deref(), &run_dir),
            Command::Gateway {
                kubeconfig,
                repo_root,
                check_only,
            } => setup::gateway(kubeconfig.as_deref(), repo_root.as_deref(), check_only),
            Command::SessionStart { project_dir } => setup::session_start(project_dir.as_deref()),
            Command::SessionStop { project_dir } => setup::session_stop(project_dir.as_deref()),
            Command::PreCompact { project_dir } => setup::pre_compact(project_dir.as_deref()),

            // --- run ---
            Command::Capture {
                kubeconfig,
                label,
                run_dir,
            } => run::capture(kubeconfig.as_deref(), &label, &run_dir),
            Command::Record(args) => run::record(
                args.repo_root.as_deref(),
                args.phase.as_deref(),
                args.label.as_deref(),
                args.cluster.as_deref(),
                &args.command,
                &args.run_dir,
            ),
            Command::Apply(args) => run::apply(
                args.kubeconfig.as_deref(),
                args.cluster.as_deref(),
                &args.manifest,
                args.step.as_deref(),
                &args.run_dir,
            ),
            Command::Validate {
                kubeconfig,
                manifest,
                output,
            } => run::validate(kubeconfig.as_deref(), &manifest, output.as_deref()),
            Command::RunnerState(args) => run::runner_state(
                args.event.as_deref(),
                args.suite_target.as_deref(),
                args.message.as_deref(),
                &args.run_dir,
            ),
            Command::Closeout { run_dir } => run::closeout(&run_dir),
            Command::Report { cmd } => run::report(&cmd),
            Command::Diff { left, right, path } => run::diff(&left, &right, path.as_deref()),
            Command::Envoy { cmd } => run::envoy(&cmd),
            Command::Kumactl { cmd } => run::kumactl(&cmd),

            // --- authoring ---
            Command::AuthoringBegin(args) => authoring::begin(
                &args.repo_root,
                &args.feature,
                &args.mode,
                &args.suite_dir,
                &args.suite_name,
            ),
            Command::AuthoringSave {
                kind,
                payload,
                input,
            } => authoring::save(&kind, payload.as_deref(), input.as_deref()),
            Command::AuthoringShow { kind } => authoring::show(&kind),
            Command::AuthoringReset { skill: _ } => authoring::reset(),
            Command::AuthoringValidate { path, repo_root } => {
                authoring::validate(&path, repo_root.as_deref())
            }
            Command::ApprovalBegin {
                skill: _,
                mode,
                suite_dir,
            } => authoring::approval_begin(&mode, suite_dir.as_deref()),
        }
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
    resolve_run_directory(&RunLookup {
        run_dir: args.run_dir.clone(),
        run_id: args.run_id.clone(),
        run_root: args.run_root.clone(),
    })
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
    let run_dir = resolve_run_dir(args)?;
    RunContext::from_run_dir(&run_dir)
}

/// Resolve a kubeconfig path from explicit argument, cluster name, or the
/// primary cluster config in the run context.
///
/// # Errors
/// Returns `CliError` when no kubeconfig can be determined.
pub(crate) fn resolve_kubeconfig(
    ctx: &RunContext,
    explicit: Option<&str>,
    cluster: Option<&str>,
) -> Result<PathBuf, CliError> {
    if let Some(kc) = explicit {
        return Ok(PathBuf::from(kc));
    }
    if let Some(cluster_name) = cluster
        && let Some(ref spec) = ctx.cluster
    {
        let configs = spec.kubeconfigs();
        if let Some(kc) = configs.get(cluster_name) {
            return Ok(PathBuf::from(*kc));
        }
    }
    if let Some(ref spec) = ctx.cluster {
        return Ok(PathBuf::from(spec.primary_kubeconfig()));
    }
    Err(CliErrorKind::missing_run_context_value("kubeconfig").into())
}
