use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::setup::wrapper::planned_agent_bootstrap_files;

use super::files::managed_root_for_path;
use super::loading::{load_plugin_sources, load_skill_sources};
use super::model::{
    AgentAssetTarget, MANAGED_ROOTS, PlannedOutput, PluginDefinition, RenderTarget,
    SkillDefinition, selected_targets,
};
use super::render_guides::render_guides;
use super::render_local_skills::render_local_skills;
use super::render_plugins::render_plugin_outputs;
use super::render_skills::render_skill_outputs;

/// Test convenience wrapper that preserves the default production behavior of
/// omitting Gemini command wrappers unless explicitly requested.
#[cfg(test)]
pub(super) fn plan_outputs(
    repo_root: &Path,
    selection: AgentAssetTarget,
    skip_runtime_hooks: &[HookAgent],
) -> Result<Vec<PlannedOutput>, CliError> {
    plan_outputs_with_gemini_commands(repo_root, selection, skip_runtime_hooks, false)
}

pub(super) fn plan_outputs_with_gemini_commands(
    repo_root: &Path,
    selection: AgentAssetTarget,
    skip_runtime_hooks: &[HookAgent],
    include_gemini_commands: bool,
) -> Result<Vec<PlannedOutput>, CliError> {
    let targets = selected_targets(selection);
    let skills = load_skill_sources(repo_root)?;
    let plugins = load_plugin_sources(repo_root, &skills)?;
    let mut outputs: BTreeMap<PathBuf, PlannedOutput> = BTreeMap::new();

    for target in targets {
        // Gemini render targets only emit `.gemini/commands/**` wrappers. The
        // managed root still gets its `AGENTS.md` guide below via `render_guides`.
        if matches!(target, RenderTarget::Gemini) && !include_gemini_commands {
            continue;
        }
        collect_target_outputs(
            repo_root,
            *target,
            &skills,
            &plugins,
            skip_runtime_hooks,
            &mut outputs,
        )?;
    }

    render_guides(
        repo_root,
        managed_roots_for_selection(selection),
        &mut outputs,
    );
    if renders_claude_local_skills(selection) {
        render_local_skills(repo_root, &mut outputs)?;
    }

    Ok(outputs.into_values().collect())
}

fn managed_roots_for_selection(selection: AgentAssetTarget) -> &'static [&'static str] {
    match selection {
        AgentAssetTarget::All => MANAGED_ROOTS,
        AgentAssetTarget::Claude => &[".claude-plugin", ".claude/skills", ".claude/plugins"],
        AgentAssetTarget::Codex => &[".agents/skills", ".agents/plugins", "plugins"],
        AgentAssetTarget::Gemini => &[".gemini/commands"],
        AgentAssetTarget::Copilot => &[".github/hooks", "plugins"],
        AgentAssetTarget::Vibe => &[".vibe/skills", ".vibe/plugins"],
        AgentAssetTarget::OpenCode => &[".opencode/skills", ".opencode/plugins"],
    }
}

fn renders_claude_local_skills(selection: AgentAssetTarget) -> bool {
    matches!(selection, AgentAssetTarget::All | AgentAssetTarget::Claude)
}

fn collect_target_outputs(
    repo_root: &Path,
    target: RenderTarget,
    skills: &[SkillDefinition],
    plugins: &[PluginDefinition],
    skip_runtime_hooks: &[HookAgent],
    outputs: &mut BTreeMap<PathBuf, PlannedOutput>,
) -> Result<(), CliError> {
    for skill in skills {
        for (path, content) in render_skill_outputs(repo_root, target, skill)? {
            insert_planned_file(repo_root, outputs, path, content)?;
        }
    }
    for plugin in plugins {
        for (path, content) in render_plugin_outputs(repo_root, target, plugin)? {
            insert_planned_file(repo_root, outputs, path, content)?;
        }
    }
    for (path, content) in render_runtime_outputs(repo_root, target, skip_runtime_hooks) {
        insert_planned_file(repo_root, outputs, path, content)?;
    }
    Ok(())
}

fn insert_planned_file(
    repo_root: &Path,
    outputs: &mut BTreeMap<PathBuf, PlannedOutput>,
    path: PathBuf,
    content: String,
) -> Result<(), CliError> {
    let managed_root = managed_root_for_path(repo_root, &path)?;
    outputs
        .entry(managed_root.clone())
        .or_insert_with(|| PlannedOutput {
            managed_root,
            files: BTreeMap::new(),
            symlinks: BTreeMap::new(),
        })
        .files
        .insert(path, content);
    Ok(())
}

pub(super) fn rebase_planned_outputs(
    source_root: &Path,
    output_root: &Path,
    planned: Vec<PlannedOutput>,
) -> Result<Vec<PlannedOutput>, CliError> {
    planned
        .into_iter()
        .map(|output| {
            let managed_root = rebase_output_path(source_root, output_root, &output.managed_root)?;
            let files = output
                .files
                .into_iter()
                .map(|(path, content)| {
                    Ok((
                        rebase_output_path(source_root, output_root, &path)?,
                        content,
                    ))
                })
                .collect::<Result<BTreeMap<_, _>, CliError>>()?;
            let symlinks = output
                .symlinks
                .into_iter()
                .map(|(link, target)| {
                    Ok((rebase_output_path(source_root, output_root, &link)?, target))
                })
                .collect::<Result<BTreeMap<_, _>, CliError>>()?;
            Ok(PlannedOutput {
                managed_root,
                files,
                symlinks,
            })
        })
        .collect()
}

fn rebase_output_path(
    source_root: &Path,
    output_root: &Path,
    path: &Path,
) -> Result<PathBuf, CliError> {
    let relative = path.strip_prefix(source_root).map_err(|error| {
        CliErrorKind::usage_error(format!(
            "generated path {} is outside source root {}: {error}",
            path.display(),
            source_root.display()
        ))
    })?;
    Ok(output_root.join(relative))
}

fn render_runtime_outputs(
    repo_root: &Path,
    target: RenderTarget,
    skip_runtime_hooks: &[HookAgent],
) -> Vec<(PathBuf, String)> {
    match target {
        RenderTarget::Copilot => {
            planned_agent_bootstrap_files(repo_root, HookAgent::Copilot, skip_runtime_hooks)
        }
        RenderTarget::Claude
        | RenderTarget::Codex
        | RenderTarget::Gemini
        | RenderTarget::Vibe
        | RenderTarget::OpenCode
        | RenderTarget::Portable => Vec::new(),
    }
}
