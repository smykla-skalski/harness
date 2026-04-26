use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::errors::CliError;
use crate::setup::wrapper::PROJECT_PLUGIN_LAUNCHER;

use super::loading::discover_plugin_sources;
use super::model::{
    PLUGINS_ROOT, PluginDefinition, PluginSource, RenderTarget, skill_alias_dir, skill_dir_name,
    skill_has_target_variant,
};
use super::render_common::copy_plugin_assets;
use super::render_skills::{
    copy_skill_extra_text_files, render_gemini_command, render_skill_markdown,
};

pub(super) fn render_plugin_outputs(
    repo_root: &Path,
    target: RenderTarget,
    plugin: &PluginDefinition,
) -> Result<BTreeMap<PathBuf, String>, CliError> {
    let mut files = BTreeMap::new();
    match target {
        RenderTarget::Claude => {
            render_claude_plugin_outputs(repo_root, repo_root, plugin, &mut files)?;
            render_skill_alias_outputs(
                repo_root,
                plugin,
                RenderTarget::Claude,
                ".claude",
                &mut files,
            )?;
        }
        RenderTarget::Codex => {
            render_codex_plugin_outputs(repo_root, plugin, &mut files)?;
            render_skill_alias_outputs(
                repo_root,
                plugin,
                RenderTarget::Codex,
                ".agents",
                &mut files,
            )?;
        }
        RenderTarget::Gemini => render_gemini_plugin_outputs(repo_root, plugin, &mut files),
        RenderTarget::Copilot => render_copilot_plugin_outputs(repo_root, plugin, &mut files)?,
        RenderTarget::Vibe => render_vibe_plugin_outputs(repo_root, plugin, &mut files)?,
        RenderTarget::OpenCode => render_opencode_plugin_outputs(repo_root, plugin, &mut files)?,
        RenderTarget::Portable => {
            unreachable!("portable plugin output is selected by host renderers");
        }
    }
    Ok(files)
}

pub(super) fn render_claude_plugin_outputs(
    output_root: &Path,
    source_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    let base = output_root
        .join(".claude")
        .join("plugins")
        .join(&plugin.source.name);
    files.insert(
        base.join(".claude-plugin").join("plugin.json"),
        render_plugin_manifest(&plugin.source),
    );
    if let Some(hooks) = &plugin.hooks {
        files.insert(base.join("hooks").join("hooks.json"), hooks.clone());
    }
    if plugin.source.name == "suite" {
        files.insert(base.join("harness"), PROJECT_PLUGIN_LAUNCHER.to_string());
    }
    copy_plugin_assets(plugin, &base, files, RenderTarget::Claude)?;
    render_plugin_skill_markdown(RenderTarget::Claude, plugin, &base, files)?;
    files.insert(
        output_root
            .join(".claude")
            .join("plugins")
            .join(".claude-plugin")
            .join("marketplace.json"),
        render_claude_marketplace(source_root)?,
    );
    files.insert(
        output_root.join(".claude-plugin").join("marketplace.json"),
        render_repo_root_marketplace(source_root)?,
    );
    Ok(())
}

fn render_codex_plugin_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    let base = repo_root.join("plugins").join(&plugin.source.name);
    let manifest = render_plugin_manifest(&plugin.source);
    files.insert(
        base.join(".codex-plugin").join("plugin.json"),
        manifest.clone(),
    );
    files.insert(base.join(".claude-plugin").join("plugin.json"), manifest);
    copy_plugin_assets(plugin, &base, files, RenderTarget::Portable)?;
    render_codex_plugin_skill_markdown(plugin, &base, files)?;
    files.insert(
        repo_root
            .join(".agents")
            .join("plugins")
            .join("marketplace.json"),
        render_codex_marketplace(repo_root)?,
    );
    Ok(())
}

fn render_gemini_plugin_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) {
    for skill in &plugin.skills {
        let path = repo_root
            .join(".gemini")
            .join("commands")
            .join(plugin.source.name.as_str())
            .join(format!(
                "{}.toml",
                super::model::gemini_command_name(&skill.source.name)
            ));
        files.insert(path, render_gemini_command(skill));
    }
}

fn render_copilot_plugin_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    let base = repo_root.join("plugins").join(&plugin.source.name);
    files.insert(
        base.join("plugin.json"),
        render_plugin_manifest(&plugin.source),
    );
    copy_plugin_assets(plugin, &base, files, RenderTarget::Portable)?;
    render_plugin_skill_markdown(RenderTarget::Portable, plugin, &base, files)
}

fn render_opencode_plugin_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    let base = repo_root
        .join(".opencode")
        .join("plugins")
        .join(&plugin.source.name);
    copy_plugin_assets(plugin, &base, files, RenderTarget::Portable)?;
    render_plugin_skill_markdown(RenderTarget::Portable, plugin, &base, files)
}

fn render_vibe_plugin_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    let base = repo_root
        .join(".vibe")
        .join("plugins")
        .join(&plugin.source.name);
    copy_plugin_assets(plugin, &base, files, RenderTarget::Portable)?;
    render_plugin_skill_markdown(RenderTarget::Portable, plugin, &base, files)
}

fn render_plugin_skill_markdown(
    target: RenderTarget,
    plugin: &PluginDefinition,
    base: &Path,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    for skill in &plugin.skills {
        let skill_base = base.join("skills").join(skill_dir_name(skill)?);
        files.insert(
            skill_base.join("SKILL.md"),
            render_skill_markdown(target, skill, None)?,
        );
        copy_skill_extra_text_files(skill, &skill_base, files, target)?;
    }
    Ok(())
}

fn render_codex_plugin_skill_markdown(
    plugin: &PluginDefinition,
    base: &Path,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    for skill in &plugin.skills {
        let target = if skill_has_target_variant(skill, RenderTarget::Codex) {
            RenderTarget::Codex
        } else {
            RenderTarget::Portable
        };
        let skill_base = base.join("skills").join(skill_dir_name(skill)?);
        files.insert(
            skill_base.join("SKILL.md"),
            render_skill_markdown(target, skill, None)?,
        );
        copy_skill_extra_text_files(skill, &skill_base, files, target)?;
    }
    Ok(())
}

fn render_skill_alias_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    target: RenderTarget,
    host_dir: &str,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    for skill in &plugin.skills {
        let Some(alias_name) = skill.source.direct_skill_name.as_deref() else {
            continue;
        };
        let alias_dir = skill_alias_dir(alias_name)?;
        let alias_base = repo_root.join(host_dir).join("skills").join(&alias_dir);
        files.insert(
            alias_base.join("SKILL.md"),
            render_skill_markdown(target, skill, Some(alias_dir.as_str()))?,
        );
        copy_skill_extra_text_files(skill, &alias_base, files, target)?;
    }
    Ok(())
}

fn render_plugin_manifest(plugin: &PluginSource) -> String {
    serde_json::to_string_pretty(&serde_json::json!({
        "name": plugin.name,
        "description": plugin.description,
        "version": plugin.version,
    }))
    .expect("typed plugin manifest serializes")
}

fn render_codex_marketplace(repo_root: &Path) -> Result<String, CliError> {
    let plugins: Vec<Value> = discover_plugin_sources(&repo_root.join(PLUGINS_ROOT))?
        .into_iter()
        .map(|plugin| {
            serde_json::json!({
                "name": plugin.name,
                "source": {
                    "source": "local",
                    "path": format!("./plugins/{}", plugin.name),
                },
                "policy": {
                    "installation": "AVAILABLE",
                    "authentication": "ON_INSTALL",
                },
                "category": "Productivity",
            })
        })
        .collect();
    Ok(serde_json::to_string_pretty(&serde_json::json!({
        "name": "harness",
        "plugins": plugins,
    }))
    .expect("typed codex marketplace serializes"))
}

fn render_claude_marketplace(repo_root: &Path) -> Result<String, CliError> {
    render_marketplace_with_prefix(repo_root, "./", false)
}

fn render_repo_root_marketplace(repo_root: &Path) -> Result<String, CliError> {
    render_marketplace_with_prefix(repo_root, "./plugins/", true)
}

fn render_marketplace_with_prefix(
    repo_root: &Path,
    source_prefix: &str,
    include_metadata: bool,
) -> Result<String, CliError> {
    let plugins: Vec<Value> = discover_plugin_sources(&repo_root.join(PLUGINS_ROOT))?
        .into_iter()
        .map(|plugin| plugin_marketplace_entry(&plugin, source_prefix))
        .collect();
    let mut root = serde_json::Map::new();
    root.insert("name".into(), Value::String("harness".into()));
    root.insert(
        "owner".into(),
        serde_json::json!({ "name": "Smykla Skalski Labs" }),
    );
    if include_metadata {
        root.insert(
            "metadata".into(),
            serde_json::json!({
                "description": "Harness test orchestration framework plugins for Kubernetes/Kuma"
            }),
        );
    }
    root.insert("plugins".into(), Value::Array(plugins));
    Ok(serde_json::to_string_pretty(&Value::Object(root))
        .expect("typed claude marketplace serializes"))
}

fn plugin_marketplace_entry(plugin: &PluginSource, source_prefix: &str) -> Value {
    let mut entry = serde_json::Map::new();
    entry.insert("name".into(), Value::String(plugin.name.clone()));
    entry.insert(
        "source".into(),
        Value::String(format!("{source_prefix}{}", plugin.name)),
    );
    entry.insert(
        "description".into(),
        Value::String(plugin.description.clone()),
    );
    if let Some(author) = &plugin.author {
        entry.insert(
            "author".into(),
            serde_json::json!({ "name": author.name.clone() }),
        );
    }
    if let Some(license) = &plugin.license {
        entry.insert("license".into(), Value::String(license.clone()));
    }
    if let Some(category) = &plugin.category {
        entry.insert("category".into(), Value::String(category.clone()));
    }
    if !plugin.tags.is_empty() {
        entry.insert(
            "tags".into(),
            Value::Array(plugin.tags.iter().cloned().map(Value::String).collect()),
        );
    }
    Value::Object(entry)
}
