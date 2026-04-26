use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;

#[cfg(test)]
mod council_tests;
mod files;
mod loading;
mod model;
mod planning;
mod render_common;
mod render_guides;
mod render_local_skills;
mod render_plugins;
mod render_skills;
mod rewrite;
#[cfg(test)]
mod tests;

use files::{ensure_outputs_match, write_outputs};
use loading::{load_plugin_sources, load_skill_sources};
pub use model::AgentAssetTarget;
use model::{PlannedOutput, repo_root};
use planning::{plan_outputs, rebase_planned_outputs};
use render_plugins::render_claude_plugin_outputs;

/// Generate checked-in multi-agent skill and plugin assets.
///
/// # Errors
/// Returns `CliError` when source assets cannot be loaded, rendered, written,
/// or verified against the checked-in outputs.
pub fn generate_agent_assets(target: AgentAssetTarget, check: bool) -> Result<i32, CliError> {
    generate_agent_assets_with_skipped_runtime_hooks(target, check, &[])
}

/// Generate checked-in multi-agent skill and plugin assets while optionally
/// omitting runtime hook config files for selected agents.
///
/// # Errors
/// Returns `CliError` when source assets cannot be loaded, rendered, written,
/// or verified against the checked-in outputs.
pub(crate) fn generate_agent_assets_with_skipped_runtime_hooks(
    target: AgentAssetTarget,
    check: bool,
    skip_runtime_hooks: &[HookAgent],
) -> Result<i32, CliError> {
    let repo_root = repo_root();
    let planned = plan_outputs(&repo_root, target, skip_runtime_hooks)?;
    if check {
        ensure_outputs_match(&planned)?;
    } else {
        write_outputs(&planned)?;
    }
    Ok(0)
}

/// Materialize the generated target outputs into a project directory.
///
/// # Errors
/// Returns `CliError` when the source assets cannot be rendered or written.
pub fn write_agent_target_outputs(
    project_root: &Path,
    target: AgentAssetTarget,
) -> Result<Vec<PathBuf>, CliError> {
    write_agent_target_outputs_with_skipped_runtime_hooks(project_root, target, &[])
}

/// Materialize the generated target outputs into a project directory while
/// optionally omitting runtime hook config files for selected agents.
///
/// # Errors
/// Returns `CliError` when the source assets cannot be rendered or written.
pub(crate) fn write_agent_target_outputs_with_skipped_runtime_hooks(
    project_root: &Path,
    target: AgentAssetTarget,
    skip_runtime_hooks: &[HookAgent],
) -> Result<Vec<PathBuf>, CliError> {
    let source_root = repo_root();
    let planned = rebase_planned_outputs(
        &source_root,
        project_root,
        plan_outputs(&source_root, target, skip_runtime_hooks)?,
    )?;
    let written = planned
        .iter()
        .flat_map(|output| output.files.keys().cloned())
        .collect::<Vec<_>>();
    write_outputs(&planned)?;
    Ok(written)
}

/// Materialize the current suite plugin payload into a project directory.
///
/// # Errors
/// Returns `CliError` when the source assets cannot be rendered or written.
pub fn write_suite_plugin_outputs(project_root: &Path) -> Result<Vec<PathBuf>, CliError> {
    let source_root = repo_root();
    let skills = load_skill_sources(&source_root)?;
    let plugins = load_plugin_sources(&source_root, &skills)?;
    let plugin = plugins
        .iter()
        .find(|plugin| plugin.source.name == "suite")
        .ok_or_else(|| CliErrorKind::usage_error("missing suite plugin source".to_string()))?;

    let mut files = BTreeMap::new();
    render_claude_plugin_outputs(project_root, &source_root, plugin, &mut files)?;

    let planned = PlannedOutput {
        managed_root: project_root.join(".claude").join("plugins"),
        files,
        symlinks: BTreeMap::new(),
    };
    let written = planned.files.keys().cloned().collect::<Vec<_>>();
    write_outputs(&[planned])?;
    Ok(written)
}
