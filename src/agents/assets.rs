use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsStr;
use std::fmt::Write as _;
use std::fs::{Permissions, metadata, set_permissions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use walkdir::WalkDir;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::infra::io::{read_text, validate_safe_segment, write_text};
use crate::setup::wrapper::{PROJECT_PLUGIN_LAUNCHER, planned_agent_bootstrap_files};

const SKILLS_ROOT: &str = "agents/skills";
const PLUGINS_ROOT: &str = "agents/plugins";

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "kebab-case")]
pub enum AgentAssetTarget {
    All,
    Claude,
    Codex,
    Gemini,
    Copilot,
    OpenCode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum RenderTarget {
    Claude,
    Codex,
    Gemini,
    Copilot,
    OpenCode,
    Portable,
}

#[derive(Debug, Clone, Deserialize)]
struct SkillSource {
    name: String,
    description: String,
    #[serde(rename = "argument-hint")]
    argument_hint: Option<String>,
    #[serde(rename = "allowed-tools")]
    allowed_tools: Option<String>,
    #[serde(rename = "disable-model-invocation")]
    disable_model_invocation: Option<bool>,
    #[serde(rename = "user-invocable")]
    user_invocable: Option<bool>,
    #[serde(rename = "direct-skill-name", alias = "codex-skill-name")]
    direct_skill_name: Option<String>,
    #[serde(default)]
    hooks: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
struct PluginSource {
    name: String,
    description: String,
    version: String,
    #[serde(default)]
    source_skill: Option<String>,
}

#[derive(Debug, Clone)]
struct SkillDefinition {
    root: PathBuf,
    source: SkillSource,
    body: String,
}

#[derive(Debug, Clone)]
struct PluginDefinition {
    root: PathBuf,
    source: PluginSource,
    hooks: Option<String>,
    skills: Vec<SkillDefinition>,
}

#[derive(Debug, Clone)]
struct PlannedOutput {
    managed_root: PathBuf,
    files: BTreeMap<PathBuf, String>,
}

/// Generate checked-in multi-agent skill and plugin assets.
///
/// # Errors
/// Returns `CliError` when source assets cannot be loaded, rendered, written,
/// or verified against the checked-in outputs.
pub fn generate_agent_assets(target: AgentAssetTarget, check: bool) -> Result<i32, CliError> {
    let repo_root = repo_root();
    let planned = plan_outputs(&repo_root, target)?;
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
    let source_root = repo_root();
    let planned = rebase_planned_outputs(
        &source_root,
        project_root,
        plan_outputs(&source_root, target)?,
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
    };
    let written = planned.files.keys().cloned().collect::<Vec<_>>();
    write_outputs(&[planned])?;
    Ok(written)
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn selected_targets(selection: AgentAssetTarget) -> &'static [RenderTarget] {
    match selection {
        AgentAssetTarget::All => &[
            RenderTarget::Claude,
            RenderTarget::Codex,
            RenderTarget::Gemini,
            RenderTarget::Copilot,
            RenderTarget::OpenCode,
        ],
        AgentAssetTarget::Claude => &[RenderTarget::Claude],
        AgentAssetTarget::Codex => &[RenderTarget::Codex],
        AgentAssetTarget::Gemini => &[RenderTarget::Gemini],
        AgentAssetTarget::Copilot => &[RenderTarget::Copilot],
        AgentAssetTarget::OpenCode => &[RenderTarget::OpenCode],
    }
}

fn plan_outputs(
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

fn rebase_planned_outputs(
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
        | RenderTarget::OpenCode
        | RenderTarget::Portable => Vec::new(),
    }
}

fn load_skill_sources(repo_root: &Path) -> Result<Vec<SkillDefinition>, CliError> {
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

fn load_plugin_sources(
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

fn load_plugin_source(plugin_root: &Path) -> Result<PluginSource, CliError> {
    let path = plugin_root.join("plugin.yaml");
    let source: PluginSource = serde_yml::from_str(&read_text(&path)?).map_err(|error| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(error.to_string())
    })?;
    validate_safe_segment(&source.name)?;
    Ok(source)
}

fn load_skill_definition(root: PathBuf) -> Result<SkillDefinition, CliError> {
    let source: SkillSource =
        serde_yml::from_str(&read_text(&root.join("skill.yaml"))?).map_err(|error| {
            CliErrorKind::invalid_json(root.join("skill.yaml").display().to_string())
                .with_details(error.to_string())
        })?;
    let body = read_text(&root.join("body.md"))?;
    Ok(SkillDefinition { root, source, body })
}

fn render_skill_outputs(
    repo_root: &Path,
    target: RenderTarget,
    skill: &SkillDefinition,
) -> Result<BTreeMap<PathBuf, String>, CliError> {
    let mut files = BTreeMap::new();
    let skill_dir = skill_dir_name(skill)?;
    match target {
        RenderTarget::Claude => {
            let base = repo_root.join(".claude").join("skills").join(&skill_dir);
            files.insert(
                base.join("SKILL.md"),
                render_skill_markdown(target, skill, None)?,
            );
            copy_extra_text_files(
                &skill.root,
                &base,
                &mut files,
                &["skill.yaml", "body.md"],
                target,
                &skill.source.name,
            )?;
        }
        RenderTarget::Codex => {
            let base = repo_root.join(".agents").join("skills").join(&skill_dir);
            files.insert(
                base.join("SKILL.md"),
                render_skill_markdown(target, skill, None)?,
            );
            copy_extra_text_files(
                &skill.root,
                &base,
                &mut files,
                &["skill.yaml", "body.md"],
                target,
                &skill.source.name,
            )?;
        }
        RenderTarget::Gemini => {
            let path = repo_root
                .join(".gemini")
                .join("commands")
                .join(format!("{}.toml", gemini_command_name(&skill.source.name)));
            files.insert(path, render_gemini_command(skill));
        }
        RenderTarget::OpenCode => {
            let base = repo_root.join(".opencode").join("skills").join(&skill_dir);
            files.insert(
                base.join("SKILL.md"),
                render_skill_markdown(target, skill, None)?,
            );
            copy_extra_text_files(
                &skill.root,
                &base,
                &mut files,
                &["skill.yaml", "body.md"],
                target,
                &skill.source.name,
            )?;
        }
        RenderTarget::Copilot | RenderTarget::Portable => {}
    }
    Ok(files)
}

fn render_plugin_outputs(
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
        RenderTarget::OpenCode => {
            render_opencode_plugin_outputs(repo_root, plugin, &mut files)?;
        }
        RenderTarget::Portable => {
            unreachable!("portable plugin output is selected by host renderers")
        }
    }
    Ok(files)
}

fn render_claude_plugin_outputs(
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
        render_claude_marketplace(source_root, plugin.source.name.as_str())?,
    );
    Ok(())
}

fn render_codex_plugin_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    let base = repo_root.join("plugins").join(&plugin.source.name);
    files.insert(
        base.join(".codex-plugin").join("plugin.json"),
        render_plugin_manifest(&plugin.source),
    );
    copy_plugin_assets(plugin, &base, files, RenderTarget::Portable)?;
    render_plugin_skill_markdown(RenderTarget::Portable, plugin, &base, files)?;
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
            .join(format!("{}.toml", gemini_command_name(&skill.source.name)));
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
        copy_extra_text_files(
            &skill.root,
            &skill_base,
            files,
            &["skill.yaml", "body.md"],
            target,
            &skill.source.name,
        )?;
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
        let alias_base = repo_root.join(host_dir).join("skills").join(alias_dir);
        files.insert(
            alias_base.join("SKILL.md"),
            render_skill_markdown(target, skill, Some(alias_name))?,
        );
        copy_extra_text_files(
            &skill.root,
            &alias_base,
            files,
            &["skill.yaml", "body.md"],
            target,
            &skill.source.name,
        )?;
    }
    Ok(())
}

fn render_skill_markdown(
    target: RenderTarget,
    skill: &SkillDefinition,
    name_override: Option<&str>,
) -> Result<String, CliError> {
    let mut out = render_skill_frontmatter(target, skill, name_override)?;
    out.push_str(&rewrite_text_for_target(
        &skill.body,
        target,
        &skill.source.name,
    ));
    Ok(out)
}

fn render_skill_frontmatter(
    target: RenderTarget,
    skill: &SkillDefinition,
    name_override: Option<&str>,
) -> Result<String, CliError> {
    let hooks = if matches!(target, RenderTarget::Portable) {
        None
    } else {
        skill
            .source
            .hooks
            .as_ref()
            .map(|value| rewrite_skill_hooks(value, target))
            .transpose()?
    };
    let mut out = String::from("---\n");
    append_yaml_line(
        &mut out,
        "name",
        name_override.unwrap_or(skill.source.name.as_str()),
    );
    append_yaml_line(&mut out, "description", &skill.source.description);
    append_optional_yaml_line(
        &mut out,
        "argument-hint",
        skill.source.argument_hint.as_deref(),
    );
    if let Some(allowed_tools) = skill.source.allowed_tools.as_deref() {
        append_yaml_line(
            &mut out,
            "allowed-tools",
            &rewrite_allowed_tools(allowed_tools, target),
        );
    }
    if let Some(disable) = skill.source.disable_model_invocation {
        writeln!(out, "disable-model-invocation: {disable}")
            .expect("writing to a string cannot fail");
    }
    if let Some(invocable) = skill.source.user_invocable {
        writeln!(out, "user-invocable: {invocable}").expect("writing to a string cannot fail");
    }
    append_optional_hooks(&mut out, hooks)?;
    out.push_str("---\n\n");
    Ok(out)
}

fn render_gemini_command(skill: &SkillDefinition) -> String {
    let prompt = rewrite_text_for_target(&skill.body, RenderTarget::Gemini, &skill.source.name);
    format!(
        "description = {}\nprompt = '''\n{}'''\n",
        toml_string(&skill.source.description),
        prompt
    )
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
                "source": format!("./{}", plugin.name),
            })
        })
        .collect();
    Ok(serde_json::to_string_pretty(&serde_json::json!({
        "name": "harness",
        "plugins": plugins,
    }))
    .expect("typed codex marketplace serializes"))
}

fn render_claude_marketplace(repo_root: &Path, _current_plugin: &str) -> Result<String, CliError> {
    let plugins: Vec<Value> = discover_plugin_sources(&repo_root.join(PLUGINS_ROOT))?
        .into_iter()
        .map(|plugin| {
            serde_json::json!({
                "name": plugin.name,
                "source": format!("./{}", plugin.name),
                "description": plugin.description,
            })
        })
        .collect();
    Ok(serde_json::to_string_pretty(&serde_json::json!({
        "name": "harness",
        "owner": { "name": "smykla-skalski" },
        "plugins": plugins,
    }))
    .expect("typed claude marketplace serializes"))
}

fn discover_plugin_sources(root: &Path) -> Result<Vec<PluginSource>, CliError> {
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

fn rewrite_allowed_tools(value: &str, target: RenderTarget) -> String {
    let mut tools = Vec::new();
    for raw in value.split(',') {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        let rewritten = match (target, trimmed) {
            (_, "AskUserQuestion") if !matches!(target, RenderTarget::Claude) => continue,
            (RenderTarget::Gemini, "Bash") => "run_shell_command",
            (RenderTarget::Gemini, "Read") => "read_file",
            (RenderTarget::Gemini, "Write") => "write_file",
            (RenderTarget::Gemini, "Edit") => "replace",
            (RenderTarget::Gemini, "Glob" | "Grep") => "search_files",
            (_, other) => other,
        };
        if !tools.iter().any(|existing| existing == rewritten) {
            tools.push(rewritten.to_string());
        }
    }
    tools.join(", ")
}

fn rewrite_skill_hooks(value: &Value, target: RenderTarget) -> Result<Value, CliError> {
    match value {
        Value::Object(map) => {
            let mut next = serde_json::Map::with_capacity(map.len());
            for (key, child) in map {
                next.insert(key.clone(), rewrite_skill_hooks(child, target)?);
            }
            Ok(Value::Object(next))
        }
        Value::Array(values) => Ok(Value::Array(
            values
                .iter()
                .map(|child| rewrite_skill_hooks(child, target))
                .collect::<Result<Vec<_>, _>>()?,
        )),
        Value::String(text) => Ok(Value::String(rewrite_hook_command(text, target))),
        other => Ok(other.clone()),
    }
}

fn rewrite_hook_command(text: &str, target: RenderTarget) -> String {
    if let Some(rest) = text.strip_prefix("harness hook --skill ") {
        return format!("harness hook --agent {} {rest}", target_name(target));
    }
    text.to_string()
}

fn rewrite_text_for_target(text: &str, target: RenderTarget, source_name: &str) -> String {
    let mut text = match target {
        RenderTarget::Portable => text.to_string(),
        _ => text.replace(
            "harness hook --skill ",
            &format!("harness hook --agent {} ", target_name(target)),
        ),
    };

    text = text
        .replace(
            "another Claude Code session",
            &format!("another {} session", target_session_label(target)),
        )
        .replace(
            "another Codex session",
            &format!("another {} session", target_session_label(target)),
        );

    if !matches!(target, RenderTarget::Claude) {
        text = rewrite_non_claude_text(text);
    }

    if source_name == "observe" {
        text = text
            .replace(
                "`$XDG_DATA_HOME/harness/observe/<SESSION_ID>.state`",
                "`~harness/projects/project-<digest>/agents/observe/<observe-id>/snapshot.json`",
            )
            .replace(
                "~/.claude/projects/",
                "~harness/projects/project-<digest>/agents/sessions/",
            )
            .replace(
                "~/.Codex/projects/",
                "~harness/projects/project-<digest>/agents/sessions/",
            )
            .replace(".claude/plugins/suite/skills/", "plugins/suite/skills/")
            .replace(".claude/skills/", "agents/skills/")
            .replace("\"$CLAUDE_PROJECT_DIR\"", "\"$PWD\"");
    }

    text
}

fn rewrite_non_claude_text(mut text: String) -> String {
    for (from, to) in [
        (
            "If Claude Code resumes this skill after compaction",
            "If this skill resumes after compaction",
        ),
        (
            "errors from Claude Code.",
            "file-state errors from the current agent.",
        ),
        (
            "Claude Code tracks file state internally -",
            "The current agent tracks file state internally -",
        ),
        ("Use AskUserQuestion", "Ask the user"),
        ("use AskUserQuestion", "ask the user"),
        ("Prompt with AskUserQuestion", "Prompt the user"),
        ("The AskUserQuestion", "The user approval prompt"),
        ("via AskUserQuestion", "via a user approval prompt"),
        ("with AskUserQuestion", "with a user approval prompt"),
        (
            "show one last AskUserQuestion",
            "show one last user approval prompt",
        ),
        (
            "re-open AskUserQuestion",
            "re-open the user approval prompt",
        ),
        ("AskUserQuestion", "user approval prompt"),
        (".claude/plugins/suite/skills/", "plugins/suite/skills/"),
        (".claude/skills/", "agents/skills/"),
        (".claude/agents", "agents/"),
    ] {
        text = text.replace(from, to);
    }
    text
}

fn skill_alias_dir(alias_name: &str) -> Result<String, CliError> {
    let alias_dir = alias_name.replace(':', "-");
    validate_safe_segment(&alias_dir)?;
    Ok(alias_dir)
}

fn skill_dir_name(skill: &SkillDefinition) -> Result<String, CliError> {
    let dir_name = skill
        .root
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| {
            CliErrorKind::usage_error(format!(
                "skill source path {} has no directory name",
                skill.root.display()
            ))
        })?
        .to_string();
    validate_safe_segment(&dir_name)?;
    Ok(dir_name)
}

fn target_label(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Claude => "Claude",
        RenderTarget::Codex => "Codex",
        RenderTarget::Gemini => "Gemini",
        RenderTarget::Copilot => "Copilot",
        RenderTarget::OpenCode => "OpenCode",
        RenderTarget::Portable => "current agent",
    }
}

fn target_name(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Claude => "claude",
        RenderTarget::Codex => "codex",
        RenderTarget::Gemini => "gemini",
        RenderTarget::Copilot => "copilot",
        RenderTarget::OpenCode => "opencode",
        RenderTarget::Portable => "portable",
    }
}

fn target_session_label(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Portable => "harness-managed",
        _ => target_label(target),
    }
}

fn gemini_command_name(skill_name: &str) -> String {
    skill_name.replace(':', "/")
}

fn copy_plugin_assets(
    plugin: &PluginDefinition,
    dest_root: &Path,
    files: &mut BTreeMap<PathBuf, String>,
    target: RenderTarget,
) -> Result<(), CliError> {
    copy_extra_text_files(
        &plugin.root,
        dest_root,
        files,
        &["plugin.yaml", "hooks.yaml", "skills"],
        target,
        &plugin.source.name,
    )
}

fn copy_extra_text_files(
    source_root: &Path,
    dest_root: &Path,
    files: &mut BTreeMap<PathBuf, String>,
    excludes: &[&str],
    target: RenderTarget,
    source_name: &str,
) -> Result<(), CliError> {
    let exclude_set: BTreeSet<&str> = excludes.iter().copied().collect();
    for entry in WalkDir::new(source_root).min_depth(1) {
        let entry = entry.map_err(|error| io_err(&error))?;
        let path = entry.path();
        let relative = path
            .strip_prefix(source_root)
            .expect("walkdir entry stays under source root");
        let first = relative
            .components()
            .next()
            .and_then(|component| component.as_os_str().to_str())
            .unwrap_or("");
        if exclude_set.contains(first) {
            continue;
        }
        if entry.file_type().is_dir() {
            continue;
        }
        let content = read_text(path)?;
        let content = if path.extension() == Some(OsStr::new("md")) {
            rewrite_text_for_target(&content, target, source_name)
        } else {
            content
        };
        files.insert(dest_root.join(relative), content);
    }
    Ok(())
}

fn managed_root_for_path(repo_root: &Path, path: &Path) -> Result<PathBuf, CliError> {
    for managed in [
        ".claude/skills",
        ".claude/plugins",
        ".agents/skills",
        ".agents/plugins",
        ".gemini/commands",
        ".github/hooks",
        ".opencode/skills",
        ".opencode/plugins",
        "plugins",
    ] {
        let root = repo_root.join(managed);
        if path.starts_with(&root) {
            return Ok(root);
        }
    }
    Err(CliErrorKind::usage_error(format!(
        "generated path {} is outside managed roots",
        path.display()
    ))
    .into())
}

fn write_outputs(planned: &[PlannedOutput]) -> Result<(), CliError> {
    for output in planned {
        let _ = &output.managed_root;
        for (path, content) in &output.files {
            write_text(path, content)?;
            if is_executable_generated_output(path) {
                set_permissions(path, Permissions::from_mode(0o755))
                    .map_err(|error| io_err(&error))?;
            }
        }
    }
    Ok(())
}

fn ensure_outputs_match(planned: &[PlannedOutput]) -> Result<(), CliError> {
    let mut drift = Vec::new();
    for output in planned {
        drift.extend(expected_output_drift(output));
        drift.extend(unexpected_output_drift(output)?);
    }
    if drift.is_empty() {
        Ok(())
    } else {
        Err(CliErrorKind::usage_error(format!(
            "generated agent assets are out of date:\n{}",
            drift.join("\n")
        ))
        .into())
    }
}

fn expected_output_drift(output: &PlannedOutput) -> Vec<String> {
    output
        .files
        .iter()
        .filter_map(|(path, expected)| match read_text(path) {
            Ok(actual) if actual == *expected => {
                if is_executable_generated_output(path) && !path_is_executable(path) {
                    Some(format!("mode drift: {}", path.display()))
                } else {
                    None
                }
            }
            Ok(_) => Some(format!("drift: {}", path.display())),
            Err(_) => Some(format!("missing: {}", path.display())),
        })
        .collect()
}

fn unexpected_output_drift(output: &PlannedOutput) -> Result<Vec<String>, CliError> {
    if !output.managed_root.exists() {
        return Ok(Vec::new());
    }

    let expected_paths: BTreeSet<&Path> = output.files.keys().map(PathBuf::as_path).collect();
    let mut drift = Vec::new();
    for entry in WalkDir::new(&output.managed_root).min_depth(1) {
        let entry = entry.map_err(|error| io_err(&error))?;
        if entry.file_type().is_dir() {
            continue;
        }
        if !expected_paths.contains(entry.path()) {
            drift.push(format!("unexpected: {}", entry.path().display()));
        }
    }
    Ok(drift)
}

fn is_executable_generated_output(path: &Path) -> bool {
    path.ends_with(Path::new(".claude/plugins/suite/harness"))
}

fn path_is_executable(path: &Path) -> bool {
    metadata(path).is_ok_and(|meta| meta.permissions().mode() & 0o111 != 0)
}

fn append_yaml_line(out: &mut String, key: &str, value: &str) {
    let rendered = yaml_serialized_lines(value, "yaml scalar").expect("yaml scalar serializes");
    if let Some((first, rest)) = rendered.split_first() {
        out.push_str(key);
        out.push_str(": ");
        out.push_str(first);
        out.push('\n');
        for line in rest {
            out.push_str("  ");
            out.push_str(line);
            out.push('\n');
        }
    }
}

fn append_optional_yaml_line(out: &mut String, key: &str, value: Option<&str>) {
    if let Some(value) = value {
        append_yaml_line(out, key, value);
    }
}

fn append_optional_hooks(out: &mut String, hooks: Option<Value>) -> Result<(), CliError> {
    if let Some(hooks) = hooks {
        out.push_str("hooks:\n");
        let hooks_yaml = yaml_serialized_lines(&hooks, "skill hooks")?;
        for line in hooks_yaml {
            out.push_str("  ");
            out.push_str(&line);
            out.push('\n');
        }
    }
    Ok(())
}

fn yaml_serialized_lines<T: Serialize + ?Sized>(
    value: &T,
    what: &str,
) -> Result<Vec<String>, CliError> {
    let rendered = serde_yml::to_string(value)
        .map_err(|error| CliErrorKind::serialize(format!("{what}: {error}")))?;
    Ok(rendered
        .lines()
        .skip(usize::from(matches!(rendered.lines().next(), Some("---"))))
        .map(ToOwned::to_owned)
        .collect())
}

fn toml_string(value: &str) -> String {
    format!("{value:?}")
}

fn io_err(error: &impl ToString) -> CliError {
    CliErrorKind::workflow_io(error.to_string()).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn sample_skill() -> SkillDefinition {
        SkillDefinition {
            root: PathBuf::from("agents/plugins/suite/skills/run"),
            source: SkillSource {
                name: "run".to_string(),
                description: "Execute suite runs through harness.".to_string(),
                argument_hint: Some("[suite-path]".to_string()),
                allowed_tools: Some(
                    "Agent, AskUserQuestion, Bash, Edit, Glob, Read, Write".to_string(),
                ),
                disable_model_invocation: Some(true),
                user_invocable: Some(true),
                direct_skill_name: None,
                hooks: Some(json!({
                    "PreToolUse": [
                        {
                            "matcher": ".*",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "harness hook --skill suite:run tool-guard"
                                }
                            ]
                        }
                    ],
                    "PostToolUse": [
                        {
                            "matcher": ".*",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "harness hook --skill suite:run tool-result"
                                }
                            ]
                        }
                    ]
                })),
            },
            body: "Run the suite through harness.".to_string(),
        }
    }

    #[test]
    fn render_skill_markdown_keeps_first_scalar_and_hook_entries() {
        let rendered = render_skill_markdown(RenderTarget::Claude, &sample_skill(), None)
            .expect("skill renders");

        assert!(rendered.starts_with("---\nname: run\n"));
        assert!(rendered.contains("description: Execute suite runs through harness.\n"));
        assert!(rendered.contains("argument-hint:"));
        assert!(rendered.contains("[suite-path]"));
        assert!(rendered.contains("allowed-tools:"));
        assert!(rendered.contains("AskUserQuestion"));
        assert!(rendered.contains("hooks:\n"));
        assert!(rendered.contains("PreToolUse"));
        assert!(rendered.contains("PostToolUse"));
        assert!(rendered.contains("---\n\n"));
        assert!(rendered.contains("Run the suite through harness."));
    }

    #[test]
    fn yaml_serialized_lines_drops_only_optional_document_marker() {
        let rendered =
            yaml_serialized_lines(&json!({"PreToolUse": []}), "hooks").expect("yaml serializes");

        assert_eq!(rendered.first().map(String::as_str), Some("PreToolUse: []"));
    }

    #[test]
    fn portable_plugin_skill_omits_host_specific_hooks_and_question_tool() {
        let rendered = render_skill_markdown(RenderTarget::Portable, &sample_skill(), None)
            .expect("skill renders");

        assert!(rendered.starts_with("---\nname: run\n"));
        assert!(rendered.contains("allowed-tools: Agent, Bash, Edit, Glob, Read, Write\n"));
        assert!(!rendered.contains("AskUserQuestion"));
        assert!(!rendered.contains("\nhooks:\n"));
        assert!(!rendered.contains("--agent copilot"));
        assert!(!rendered.contains("--agent codex"));
    }

    #[test]
    fn copilot_generation_includes_repo_hook_config() {
        let planned =
            plan_outputs(&repo_root(), AgentAssetTarget::Copilot).expect("assets plan succeeds");
        let hook_path = repo_root()
            .join(".github")
            .join("hooks")
            .join("harness.json");
        let hook_output = planned
            .iter()
            .find_map(|output| output.files.get(&hook_path))
            .expect("copilot hook config should be generated");

        assert!(hook_output.contains("\"version\": 1"));
        assert!(hook_output.contains("\"userPromptSubmitted\""));
        assert!(hook_output.contains(
            "\"harness agents session-start --agent copilot --project-dir \\\"$PWD\\\"\""
        ));
    }

    #[test]
    fn shared_plugin_outputs_stay_portable_across_codex_and_copilot() {
        let planned =
            plan_outputs(&repo_root(), AgentAssetTarget::All).expect("assets plan succeeds");
        let shared_skill = repo_root()
            .join("plugins")
            .join("suite")
            .join("skills")
            .join("create")
            .join("SKILL.md");
        let rendered = planned
            .iter()
            .find_map(|output| output.files.get(&shared_skill))
            .expect("shared plugin skill should be planned");

        assert!(!rendered.contains("--agent codex"));
        assert!(!rendered.contains("--agent copilot"));
        assert!(!rendered.contains("matcher: AskUserQuestion"));
        assert!(rendered.contains("user approval prompt"));
    }

    #[test]
    fn harness_plugin_is_in_codex_marketplace() {
        let planned =
            plan_outputs(&repo_root(), AgentAssetTarget::Codex).expect("assets plan succeeds");
        let marketplace = repo_root()
            .join(".agents")
            .join("plugins")
            .join("marketplace.json");
        let rendered = planned
            .iter()
            .find_map(|output| output.files.get(&marketplace))
            .expect("codex marketplace should be planned");

        assert!(rendered.contains("\"name\": \"harness\""));
        assert!(rendered.contains("\"source\": \"./harness\""));
    }

    #[test]
    fn codex_session_skill_aliases_are_planned() {
        let planned =
            plan_outputs(&repo_root(), AgentAssetTarget::Codex).expect("assets plan succeeds");
        let alias = repo_root()
            .join(".agents")
            .join("skills")
            .join("harness-session-start")
            .join("SKILL.md");
        let rendered = planned
            .iter()
            .find_map(|output| output.files.get(&alias))
            .expect("harness:session:start alias should be planned");

        assert!(rendered.contains("name: harness:session:start"));
        assert!(!rendered.contains("AskUserQuestion"));
        assert!(rendered.contains("ask the user first"));
    }

    #[test]
    fn claude_session_plugin_skill_is_namespaced_under_harness() {
        let planned =
            plan_outputs(&repo_root(), AgentAssetTarget::Claude).expect("assets plan succeeds");
        let skill = repo_root()
            .join(".claude")
            .join("plugins")
            .join("harness")
            .join("skills")
            .join("start")
            .join("SKILL.md");
        let rendered = planned
            .iter()
            .find_map(|output| output.files.get(&skill))
            .expect("Claude harness session skill should be planned");

        assert!(rendered.contains("name: session:start"));
        assert!(rendered.contains("AskUserQuestion"));
    }

    #[test]
    fn claude_session_skill_aliases_are_planned() {
        let planned =
            plan_outputs(&repo_root(), AgentAssetTarget::Claude).expect("assets plan succeeds");
        let alias = repo_root()
            .join(".claude")
            .join("skills")
            .join("harness-session-start")
            .join("SKILL.md");
        let rendered = planned
            .iter()
            .find_map(|output| output.files.get(&alias))
            .expect("harness:session:start alias should be planned for Claude");

        assert!(rendered.contains("name: harness:session:start"));
        assert!(rendered.contains("AskUserQuestion"));
    }

    #[test]
    fn gemini_session_plugin_command_is_namespaced_under_harness() {
        let planned =
            plan_outputs(&repo_root(), AgentAssetTarget::Gemini).expect("assets plan succeeds");
        let command = repo_root()
            .join(".gemini")
            .join("commands")
            .join("harness")
            .join("session")
            .join("start.toml");
        let rendered = planned
            .iter()
            .find_map(|output| output.files.get(&command))
            .expect("Gemini harness session command should be planned");

        assert!(rendered.contains("Start a new multi-agent orchestration session."));
        assert!(rendered.contains("harness session start"));
    }
}
