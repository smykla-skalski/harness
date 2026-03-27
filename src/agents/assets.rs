use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsStr;
use std::fmt::Write as _;
use std::fs::{Permissions, metadata, set_permissions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use clap::ValueEnum;
use serde::Deserialize;
use serde_json::Value;
use walkdir::WalkDir;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, validate_safe_segment, write_text};
use crate::setup::wrapper::PROJECT_PLUGIN_LAUNCHER;

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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum RenderTarget {
    Claude,
    Codex,
    Gemini,
    Copilot,
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
        ],
        AgentAssetTarget::Claude => &[RenderTarget::Claude],
        AgentAssetTarget::Codex => &[RenderTarget::Codex],
        AgentAssetTarget::Gemini => &[RenderTarget::Gemini],
        AgentAssetTarget::Copilot => &[RenderTarget::Copilot],
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
    }

    Ok(grouped
        .into_iter()
        .map(|(managed_root, files)| PlannedOutput {
            managed_root,
            files,
        })
        .collect())
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
        let source: PluginSource = serde_yml::from_str(&read_text(
            &plugin_root.join("plugin.yaml"),
        )?)
        .map_err(|error| {
            CliErrorKind::invalid_json(plugin_root.join("plugin.yaml").display().to_string())
                .with_details(error.to_string())
        })?;
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
    match target {
        RenderTarget::Claude => {
            let base = repo_root
                .join(".claude")
                .join("skills")
                .join(&skill.source.name);
            files.insert(base.join("SKILL.md"), render_skill_markdown(target, skill)?);
            copy_extra_text_files(&skill.root, &base, &mut files, &["skill.yaml", "body.md"])?;
        }
        RenderTarget::Codex => {
            let base = repo_root
                .join(".agents")
                .join("skills")
                .join(&skill.source.name);
            files.insert(base.join("SKILL.md"), render_skill_markdown(target, skill)?);
            copy_extra_text_files(&skill.root, &base, &mut files, &["skill.yaml", "body.md"])?;
        }
        RenderTarget::Gemini => {
            let path = repo_root
                .join(".gemini")
                .join("commands")
                .join(format!("{}.toml", gemini_command_name(&skill.source.name)));
            files.insert(path, render_gemini_command(skill));
        }
        RenderTarget::Copilot => {}
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
        RenderTarget::Claude => render_claude_plugin_outputs(repo_root, plugin, &mut files)?,
        RenderTarget::Codex => render_codex_plugin_outputs(repo_root, plugin, &mut files)?,
        RenderTarget::Gemini => render_gemini_plugin_outputs(repo_root, plugin, &mut files),
        RenderTarget::Copilot => render_copilot_plugin_outputs(repo_root, plugin, &mut files)?,
    }
    Ok(files)
}

fn render_claude_plugin_outputs(
    repo_root: &Path,
    plugin: &PluginDefinition,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    let base = repo_root
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
    copy_plugin_assets(plugin, &base, files)?;
    render_plugin_skill_markdown(RenderTarget::Claude, plugin, &base, files)?;
    files.insert(
        repo_root
            .join(".claude")
            .join("plugins")
            .join(".claude-plugin")
            .join("marketplace.json"),
        render_claude_marketplace(repo_root, plugin.source.name.as_str())?,
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
    copy_plugin_assets(plugin, &base, files)?;
    render_plugin_skill_markdown(RenderTarget::Codex, plugin, &base, files)?;
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
            .join(format!("{}.toml", skill.source.name));
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
    copy_plugin_assets(plugin, &base, files)?;
    render_plugin_skill_markdown(RenderTarget::Copilot, plugin, &base, files)
}

fn render_plugin_skill_markdown(
    target: RenderTarget,
    plugin: &PluginDefinition,
    base: &Path,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    for skill in &plugin.skills {
        let skill_base = base.join("skills").join(&skill.source.name);
        files.insert(
            skill_base.join("SKILL.md"),
            render_skill_markdown(target, skill)?,
        );
        copy_extra_text_files(&skill.root, &skill_base, files, &["skill.yaml", "body.md"])?;
    }
    Ok(())
}

fn render_skill_markdown(
    target: RenderTarget,
    skill: &SkillDefinition,
) -> Result<String, CliError> {
    let hooks = skill
        .source
        .hooks
        .as_ref()
        .map(|value| rewrite_skill_hooks(value, target))
        .transpose()?;
    let mut out = String::from("---\n");
    append_yaml_line(&mut out, "name", &skill.source.name);
    append_yaml_line(&mut out, "description", &skill.source.description);
    if let Some(argument_hint) = skill.source.argument_hint.as_deref() {
        append_yaml_line(&mut out, "argument-hint", argument_hint);
    }
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
    if let Some(hooks) = hooks {
        out.push_str("hooks:\n");
        let hooks_yaml = serde_yml::to_string(&hooks)
            .map_err(|error| CliErrorKind::serialize(format!("skill hooks: {error}")))?;
        for line in hooks_yaml.lines().skip(1) {
            out.push_str("  ");
            out.push_str(line);
            out.push('\n');
        }
    }
    out.push_str("---\n\n");
    out.push_str(&rewrite_body_for_target(
        &skill.body,
        target,
        &skill.source.name,
    ));
    Ok(out)
}

fn render_gemini_command(skill: &SkillDefinition) -> String {
    let prompt = rewrite_body_for_target(&skill.body, RenderTarget::Gemini, &skill.source.name);
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
    let plugin_names = discover_plugin_names(&repo_root.join(PLUGINS_ROOT))?;
    let plugins: Vec<Value> = plugin_names
        .into_iter()
        .map(|name| {
            serde_json::json!({
                "name": name,
                "source": format!("./{name}"),
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
    let plugin_names = discover_plugin_names(&repo_root.join(PLUGINS_ROOT))?;
    let plugins: Vec<Value> = plugin_names
        .into_iter()
        .map(|name| {
            serde_json::json!({
                "name": name,
                "source": format!("./{name}"),
                "description": format!("Harness {name} workflow"),
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

fn discover_plugin_names(root: &Path) -> Result<Vec<String>, CliError> {
    let mut names = Vec::new();
    for entry in root.read_dir().map_err(|error| io_err(&error))? {
        let entry = entry.map_err(|error| io_err(&error))?;
        if entry.file_type().map_err(|error| io_err(&error))?.is_dir() {
            let name = entry.file_name().to_string_lossy().to_string();
            validate_safe_segment(&name)?;
            names.push(name);
        }
    }
    names.sort();
    Ok(names)
}

fn rewrite_allowed_tools(value: &str, target: RenderTarget) -> String {
    let mut tools = Vec::new();
    for raw in value.split(',') {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        let rewritten = match (target, trimmed) {
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

fn rewrite_body_for_target(body: &str, target: RenderTarget, skill_name: &str) -> String {
    let mut text = body
        .replace(
            "harness hook --skill ",
            &format!("harness hook --agent {} ", target_name(target)),
        )
        .replace(
            "another Claude Code session",
            &format!("another {} session", target_label(target)),
        )
        .replace(
            "another Codex session",
            &format!("another {} session", target_label(target)),
        );
    if skill_name == "observe" {
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
            .replace("\"$CLAUDE_PROJECT_DIR\"", "\"$PWD\"");
    }
    text
}

fn target_label(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Claude => "Claude",
        RenderTarget::Codex => "Codex",
        RenderTarget::Gemini => "Gemini",
        RenderTarget::Copilot => "Copilot",
    }
}

fn target_name(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Claude => "claude",
        RenderTarget::Codex => "codex",
        RenderTarget::Gemini => "gemini",
        RenderTarget::Copilot => "copilot",
    }
}

fn gemini_command_name(skill_name: &str) -> String {
    skill_name.replace(':', "/")
}

fn copy_plugin_assets(
    plugin: &PluginDefinition,
    dest_root: &Path,
    files: &mut BTreeMap<PathBuf, String>,
) -> Result<(), CliError> {
    copy_extra_text_files(
        &plugin.root,
        dest_root,
        files,
        &["plugin.yaml", "hooks.yaml", "skills"],
    )
}

fn copy_extra_text_files(
    source_root: &Path,
    dest_root: &Path,
    files: &mut BTreeMap<PathBuf, String>,
    excludes: &[&str],
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
        if path.extension() == Some(OsStr::new("json"))
            || path.extension() == Some(OsStr::new("md"))
        {
            files.insert(dest_root.join(relative), read_text(path)?);
            continue;
        }
        files.insert(dest_root.join(relative), read_text(path)?);
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
    metadata(path)
        .map(|meta| meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

fn append_yaml_line(out: &mut String, key: &str, value: &str) {
    let rendered = serde_yml::to_string(value).expect("yaml scalar serializes");
    if let Some(line) = rendered.lines().nth(1) {
        out.push_str(key);
        out.push_str(": ");
        out.push_str(line);
        out.push('\n');
    }
}

fn toml_string(value: &str) -> String {
    format!("{value:?}")
}

fn io_err(error: &impl ToString) -> CliError {
    CliErrorKind::workflow_io(error.to_string()).into()
}
