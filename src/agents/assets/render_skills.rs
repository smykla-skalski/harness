use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};

use super::model::{RenderTarget, SkillDefinition, gemini_command_name, skill_dir_name};
use super::render_common::copy_extra_text_files;
use super::rewrite::{rewrite_allowed_tools, rewrite_skill_hooks, rewrite_text_for_target};

pub(super) fn render_skill_outputs(
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
        RenderTarget::Vibe => {
            let base = repo_root.join(".vibe").join("skills").join(&skill_dir);
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

pub(super) fn render_skill_markdown(
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

pub(super) fn render_gemini_command(skill: &SkillDefinition) -> String {
    let prompt = rewrite_text_for_target(&skill.body, RenderTarget::Gemini, &skill.source.name);
    format!(
        "description = {}\nprompt = '''\n{}'''\n",
        toml_string(&skill.source.description),
        prompt
    )
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

pub(super) fn yaml_serialized_lines<T: Serialize + ?Sized>(
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
