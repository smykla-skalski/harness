use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::setup::wrapper::planned_agent_bootstrap_files;

use super::files::managed_root_for_path;
use super::loading::{load_plugin_sources, load_skill_sources};
use super::model::{AgentAssetTarget, PlannedOutput, RenderTarget, selected_targets};
use super::render_plugins::render_plugin_outputs;
use super::render_skills::render_skill_outputs;

pub(super) fn plan_outputs(
    repo_root: &Path,
    selection: AgentAssetTarget,
) -> Result<Vec<PlannedOutput>, CliError> {
    let targets = selected_targets(selection);
    let skills = load_skill_sources(repo_root)?;
    let plugins = load_plugin_sources(repo_root, &skills)?;
    let mut grouped: BTreeMap<PathBuf, BTreeMap<PathBuf, String>> = BTreeMap::new();

    for target in targets {
        for skill in &skills {
            for (path, content) in render_skill_outputs(repo_root, *target, skill)? {
                let managed_root = managed_root_for_path(repo_root, &path)?;
                grouped
                    .entry(managed_root)
                    .or_default()
                    .insert(path, content);
            }
        }
        for plugin in &plugins {
            for (path, content) in render_plugin_outputs(repo_root, *target, plugin)? {
                let managed_root = managed_root_for_path(repo_root, &path)?;
                grouped
                    .entry(managed_root)
                    .or_default()
                    .insert(path, content);
            }
        }
        for (path, content) in render_runtime_outputs(repo_root, *target) {
            let managed_root = managed_root_for_path(repo_root, &path)?;
            grouped
                .entry(managed_root)
                .or_default()
                .insert(path, content);
        }
    }

    Ok(grouped
        .into_iter()
        .map(|(managed_root, files)| PlannedOutput {
            managed_root,
            files,
        })
        .collect())
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
            Ok(PlannedOutput {
                managed_root,
                files,
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

fn render_runtime_outputs(repo_root: &Path, target: RenderTarget) -> Vec<(PathBuf, String)> {
    match target {
        RenderTarget::Copilot => planned_agent_bootstrap_files(repo_root, HookAgent::Copilot),
        RenderTarget::Claude
        | RenderTarget::Codex
        | RenderTarget::Gemini
        | RenderTarget::Vibe
        | RenderTarget::OpenCode
        | RenderTarget::Portable => Vec::new(),
    }
}
