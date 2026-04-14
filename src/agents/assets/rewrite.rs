use serde_json::Value;

use crate::errors::CliError;

use super::model::{RenderTarget, target_name, target_session_label};

pub(super) fn rewrite_allowed_tools(value: &str, target: RenderTarget) -> String {
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

pub(super) fn rewrite_skill_hooks(value: &Value, target: RenderTarget) -> Result<Value, CliError> {
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

pub(super) fn rewrite_text_for_target(
    text: &str,
    target: RenderTarget,
    source_name: &str,
) -> String {
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
