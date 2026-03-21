use crate::kernel::tooling::{ToolInput, legacy_tool_context};

use super::super::truncate_at;

/// A formatted dump block with a label prefix and the block text.
pub(crate) struct DumpBlock {
    pub label: String,
    pub text: String,
}

/// Extract text from a `tool_result` content block.
pub(crate) fn tool_result_text(block: &serde_json::Value) -> String {
    let content = &block["content"];
    if let Some(arr) = content.as_array() {
        let parts: Vec<&str> = arr
            .iter()
            .filter_map(|item| {
                if item["type"].as_str() == Some("text") {
                    item["text"].as_str()
                } else {
                    None
                }
            })
            .collect();
        parts.join("\n")
    } else if let Some(s) = content.as_str() {
        s.to_string()
    } else {
        String::new()
    }
}

/// Format a content block for dump output.
pub(crate) fn format_dump_block(index: usize, role: &str, block: &serde_json::Value) -> DumpBlock {
    let block_type = block["type"].as_str().unwrap_or("");
    let block_id = block["id"]
        .as_str()
        .or_else(|| block["tool_use_id"].as_str())
        .unwrap_or("");
    let id_suffix = if block_id.is_empty() {
        String::new()
    } else {
        format!(" ({block_id})")
    };

    match block_type {
        "text" => {
            let text = block["text"].as_str().unwrap_or("").to_string();
            DumpBlock {
                label: format!("L{index} [{role}] text"),
                text,
            }
        }
        "tool_use" => format_tool_use_dump(index, role, block, &id_suffix),
        "tool_result" => {
            let text = tool_result_text(block);
            DumpBlock {
                label: format!("L{index} [{role}] result{id_suffix}"),
                text,
            }
        }
        _ => DumpBlock {
            label: format!("L{index} [{role}] {block_type}{id_suffix}"),
            text: String::new(),
        },
    }
}

fn format_tool_use_dump(
    index: usize,
    role: &str,
    block: &serde_json::Value,
    id_suffix: &str,
) -> DumpBlock {
    let name = block["name"].as_str().unwrap_or("");
    let input = &block["input"];
    let tool = legacy_tool_context(name, input.clone(), None);
    match &tool.input {
        ToolInput::Shell { command, .. } => DumpBlock {
            label: format!("L{index} [{role}] Bash{id_suffix}"),
            text: command.clone(),
        },
        ToolInput::FileRead { paths } | ToolInput::FileWrite { paths, .. } => DumpBlock {
            label: format!("L{index} [{role}] {name}{id_suffix}"),
            text: paths
                .first()
                .map_or_else(String::new, |path| path.display().to_string()),
        },
        ToolInput::FileEdit {
            path,
            old_text,
            new_text,
        } => {
            let old = truncate_at(old_text, 100);
            let new_str = truncate_at(new_text, 100);
            DumpBlock {
                label: format!("L{index} [{role}] Edit{id_suffix}"),
                text: format!("{}\n  old: {old}\n  new: {new_str}", path.display()),
            }
        }
        ToolInput::Other(input) if name == "AskUserQuestion" => {
            let questions = input["questions"].as_array();
            let parts: Vec<String> = questions
                .iter()
                .flat_map(|qs| qs.iter())
                .map(|q| {
                    let header = q["header"].as_str().unwrap_or("");
                    let question = q["question"].as_str().unwrap_or("");
                    format!("header={header}, q={question}")
                })
                .collect();
            DumpBlock {
                label: format!("L{index} [{role}] AskUser{id_suffix}"),
                text: parts.join("; "),
            }
        }
        ToolInput::Other(input) if name == "Agent" => {
            let desc = input["description"].as_str().unwrap_or("");
            DumpBlock {
                label: format!("L{index} [{role}] Agent{id_suffix}"),
                text: desc.to_string(),
            }
        }
        ToolInput::FileSearch { pattern, .. } => DumpBlock {
            label: format!("L{index} [{role}] {name}{id_suffix}"),
            text: pattern.clone(),
        },
        ToolInput::Other(input) => {
            let raw = serde_json::to_string(input).unwrap_or_default();
            DumpBlock {
                label: format!("L{index} [{role}] {name}{id_suffix}"),
                text: truncate_at(&raw, 300).to_string(),
            }
        }
    }
}

pub(crate) fn timestamp_suffix(timestamp: &str) -> String {
    if timestamp.is_empty() {
        String::new()
    } else {
        format!(" {timestamp}")
    }
}
