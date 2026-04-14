use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, validate_safe_segment};

use super::files::io_err;
use super::model::{
    PLUGINS_ROOT, PluginDefinition, PluginSource, SKILLS_ROOT, SkillDefinition, SkillSource,
};

pub(super) fn load_skill_sources(repo_root: &Path) -> Result<Vec<SkillDefinition>, CliError> {
    let root = repo_root.join(SKILLS_ROOT);
    let mut skills = Vec::new();
    for entry in root.read_dir().map_err(|error| io_err(&error))? {
        let entry = entry.map_err(|error| io_err(&error))?;
        if !entry.file_type().map_err(|error| io_err(&error))?.is_dir() {
            continue;
        }
        skills.push(load_skill_definition(entry.path())?);
    }
    skills.sort_by(|a, b| a.source.name.cmp(&b.source.name));
    Ok(skills)
}

pub(super) fn load_plugin_sources(
    repo_root: &Path,
    shared_skills: &[SkillDefinition],
) -> Result<Vec<PluginDefinition>, CliError> {
    let root = repo_root.join(PLUGINS_ROOT);
    let mut plugins = Vec::new();
    for entry in root.read_dir().map_err(|error| io_err(&error))? {
        let entry = entry.map_err(|error| io_err(&error))?;
        if !entry.file_type().map_err(|error| io_err(&error))?.is_dir() {
            continue;
        }
        let plugin_root = entry.path();
        let source = load_plugin_source(&plugin_root)?;
        let hooks = {
            let path = plugin_root.join("hooks.yaml");
            path.exists().then(|| read_text(&path)).transpose()?
        };
        let mut skills = Vec::new();
        let plugin_skills_root = plugin_root.join("skills");
        if plugin_skills_root.is_dir() {
            for skill_dir in plugin_skills_root
                .read_dir()
                .map_err(|error| io_err(&error))?
            {
                let skill_dir = skill_dir.map_err(|error| io_err(&error))?;
                if !skill_dir
                    .file_type()
                    .map_err(|error| io_err(&error))?
                    .is_dir()
                {
                    continue;
                }
                skills.push(load_skill_definition(skill_dir.path())?);
            }
        }
        if let Some(skill_name) = source.source_skill.as_deref() {
            let Some(shared) = shared_skills
                .iter()
                .find(|skill| skill.source.name == skill_name)
            else {
                return Err(CliErrorKind::usage_error(format!(
                    "plugin `{}` references missing shared skill `{skill_name}`",
                    source.name
                ))
                .into());
            };
            skills.push(shared.clone());
        }
        skills.sort_by(|a, b| a.source.name.cmp(&b.source.name));
        plugins.push(PluginDefinition {
            root: plugin_root,
            source,
            hooks,
            skills,
        });
    }
    plugins.sort_by(|a, b| a.source.name.cmp(&b.source.name));
    Ok(plugins)
}

pub(super) fn load_plugin_source(plugin_root: &Path) -> Result<PluginSource, CliError> {
    let path = plugin_root.join("plugin.yaml");
    let source: PluginSource = serde_yml::from_str(&read_text(&path)?).map_err(|error| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(error.to_string())
    })?;
    validate_safe_segment(&source.name)?;
    Ok(source)
}

pub(super) fn load_skill_definition(root: PathBuf) -> Result<SkillDefinition, CliError> {
    let source: SkillSource =
        serde_yml::from_str(&read_text(&root.join("skill.yaml"))?).map_err(|error| {
            CliErrorKind::invalid_json(root.join("skill.yaml").display().to_string())
                .with_details(error.to_string())
        })?;
    let body = read_text(&root.join("body.md"))?;
    Ok(SkillDefinition { root, source, body })
}

pub(super) fn discover_plugin_sources(root: &Path) -> Result<Vec<PluginSource>, CliError> {
    let mut plugins = Vec::new();
    for entry in root.read_dir().map_err(|error| io_err(&error))? {
        let entry = entry.map_err(|error| io_err(&error))?;
        if entry.file_type().map_err(|error| io_err(&error))?.is_dir() {
            plugins.push(load_plugin_source(&entry.path())?);
        }
    }
    plugins.sort_by(|a, b| a.name.cmp(&b.name));
    plugins.dedup_by(|a, b| a.name == b.name);
    Ok(plugins)
}
