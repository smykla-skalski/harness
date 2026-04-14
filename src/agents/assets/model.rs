use std::env;
use std::ffi::OsStr;
use std::path::PathBuf;

use clap::ValueEnum;
use serde::Deserialize;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::validate_safe_segment;

pub(super) const SKILLS_ROOT: &str = "agents/skills";
pub(super) const PLUGINS_ROOT: &str = "agents/plugins";

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "kebab-case")]
pub enum AgentAssetTarget {
    All,
    Claude,
    Codex,
    Gemini,
    Copilot,
    Vibe,
    OpenCode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum RenderTarget {
    Claude,
    Codex,
    Gemini,
    Copilot,
    Vibe,
    OpenCode,
    Portable,
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct SkillSource {
    pub(super) name: String,
    pub(super) description: String,
    #[serde(rename = "argument-hint")]
    pub(super) argument_hint: Option<String>,
    #[serde(rename = "allowed-tools")]
    pub(super) allowed_tools: Option<String>,
    #[serde(rename = "disable-model-invocation")]
    pub(super) disable_model_invocation: Option<bool>,
    #[serde(rename = "user-invocable")]
    pub(super) user_invocable: Option<bool>,
    #[serde(rename = "direct-skill-name", alias = "codex-skill-name")]
    pub(super) direct_skill_name: Option<String>,
    #[serde(default)]
    pub(super) hooks: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct PluginSource {
    pub(super) name: String,
    pub(super) description: String,
    pub(super) version: String,
    #[serde(default)]
    pub(super) source_skill: Option<String>,
}

#[derive(Debug, Clone)]
pub(super) struct SkillDefinition {
    pub(super) root: PathBuf,
    pub(super) source: SkillSource,
    pub(super) body: String,
}

#[derive(Debug, Clone)]
pub(super) struct PluginDefinition {
    pub(super) root: PathBuf,
    pub(super) source: PluginSource,
    pub(super) hooks: Option<String>,
    pub(super) skills: Vec<SkillDefinition>,
}

#[derive(Debug, Clone)]
pub(super) struct PlannedOutput {
    pub(super) managed_root: PathBuf,
    pub(super) files: std::collections::BTreeMap<PathBuf, String>,
}

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

pub(super) fn selected_targets(selection: AgentAssetTarget) -> &'static [RenderTarget] {
    match selection {
        AgentAssetTarget::All => &[
            RenderTarget::Claude,
            RenderTarget::Codex,
            RenderTarget::Gemini,
            RenderTarget::Copilot,
            RenderTarget::Vibe,
            RenderTarget::OpenCode,
        ],
        AgentAssetTarget::Claude => &[RenderTarget::Claude],
        AgentAssetTarget::Codex => &[RenderTarget::Codex],
        AgentAssetTarget::Gemini => &[RenderTarget::Gemini],
        AgentAssetTarget::Copilot => &[RenderTarget::Copilot],
        AgentAssetTarget::Vibe => &[RenderTarget::Vibe],
        AgentAssetTarget::OpenCode => &[RenderTarget::OpenCode],
    }
}

pub(super) fn skill_alias_dir(alias_name: &str) -> Result<String, CliError> {
    let alias_dir = alias_name.replace(':', "-");
    validate_safe_segment(&alias_dir)?;
    Ok(alias_dir)
}

pub(super) fn skill_dir_name(skill: &SkillDefinition) -> Result<String, CliError> {
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

pub(super) fn target_label(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Claude => "Claude",
        RenderTarget::Codex => "Codex",
        RenderTarget::Gemini => "Gemini",
        RenderTarget::Copilot => "Copilot",
        RenderTarget::Vibe => "Vibe",
        RenderTarget::OpenCode => "OpenCode",
        RenderTarget::Portable => "current agent",
    }
}

pub(super) fn target_name(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Claude => "claude",
        RenderTarget::Codex => "codex",
        RenderTarget::Gemini => "gemini",
        RenderTarget::Copilot => "copilot",
        RenderTarget::Vibe => "vibe",
        RenderTarget::OpenCode => "opencode",
        RenderTarget::Portable => "portable",
    }
}

pub(super) fn target_session_label(target: RenderTarget) -> &'static str {
    match target {
        RenderTarget::Portable => "harness-managed",
        _ => target_label(target),
    }
}

pub(super) fn gemini_command_name(skill_name: &str) -> String {
    skill_name.replace(':', "/")
}
