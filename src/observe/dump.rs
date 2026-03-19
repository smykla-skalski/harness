use std::fs;
use std::io::{BufRead, BufReader};

use crate::errors::{CliError, CliErrorKind};
use crate::kernel::tooling::{ToolInput, legacy_tool_context};

use super::session;
use super::{DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, truncate_at};

pub(super) struct DumpOptions<'a> {
    pub from_line: usize,
    pub to_line: Option<usize>,
    pub text_filter: Option<&'a str>,
    pub roles: Option<&'a str>,
    pub tool_name: Option<&'a str>,
    pub raw_json: bool,
}

/// Parsed fields from a valid dump JSONL line.
struct ParsedDumpLine<'a> {
    role: &'a str,
    timestamp: &'a str,
    message: &'a serde_json::Value,
}

/// A formatted dump block with a label prefix and the block text.
pub(super) struct DumpBlock {
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

/// Parse a JSONL object and return the message fields if it passes role filters.
fn parse_dump_line<'a>(
    obj: &'a serde_json::Value,
    role_set: Option<&[&str]>,
) -> Option<ParsedDumpLine<'a>> {
    let message = &obj["message"];
    if !message.is_object() {
        return None;
    }
    let role = message["role"].as_str().unwrap_or("");
    if role_set.is_some_and(|rs| !rs.contains(&role)) {
        return None;
    }
    let timestamp = obj["timestamp"].as_str().unwrap_or("");
    Some(ParsedDumpLine {
        role,
        timestamp,
        message,
    })
}

/// Execute dump mode - raw event stream without classification.
pub(super) fn execute_dump(
    session_id: &str,
    options: &DumpOptions<'_>,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let DumpOptions {
        from_line,
        to_line,
        text_filter,
        roles,
        tool_name,
        raw_json,
    } = *options;
    let path = session::find_session(session_id, project_hint)?;
    let file = fs::File::open(&path)
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot open session file: {e}")))?;
    let reader = BufReader::new(file);
    let role_set: Option<Vec<&str>> = roles.map(|r| r.split(',').collect());
    let filter_lower: Option<String> = text_filter.map(str::to_lowercase);

    for (index, line_result) in reader.lines().enumerate() {
        if index < from_line {
            continue;
        }
        if to_line.is_some_and(|end| index > end) {
            break;
        }
        let Ok(line) = line_result else { continue };
        let Ok(obj) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            continue;
        };

        let Some(parsed) = parse_dump_line(&obj, role_set.as_deref()) else {
            continue;
        };

        if raw_json {
            if filter_lower
                .as_deref()
                .is_some_and(|f| !line.to_lowercase().contains(f))
            {
                continue;
            }
            println!("{}", line.trim());
            continue;
        }

        dump_message_content(
            index,
            parsed.role,
            parsed.timestamp,
            &parsed.message["content"],
            filter_lower.as_deref(),
            tool_name,
        );
    }

    Ok(0)
}

/// Check if pre-lowered text matches the pre-lowercased dump filter.
fn matches_dump_filter(text_lower: &str, filter_lower: Option<&str>) -> bool {
    filter_lower.is_none_or(|f| text_lower.contains(f))
}

/// Check whether a content block passes the tool-name filter.
///
/// Returns `true` if there is no filter or if the block matches.
/// Returns `false` if the block should be skipped.
fn passes_tool_name_filter(block: &serde_json::Value, filter: Option<&str>) -> bool {
    let Some(name_filter) = filter else {
        return true;
    };
    let block_type = block["type"].as_str().unwrap_or("");
    if block_type == "tool_use" {
        let name = block["name"].as_str().unwrap_or("");
        return name.eq_ignore_ascii_case(name_filter);
    }
    // Can't correlate tool_result by name, so skip when filter is active
    block_type != "tool_result"
}

/// Print content blocks from a message in dump format.
fn dump_message_content(
    index: usize,
    role: &str,
    timestamp: &str,
    content: &serde_json::Value,
    filter_lower: Option<&str>,
    tool_name_filter: Option<&str>,
) {
    if let Some(blocks) = content.as_array() {
        dump_content_blocks(
            index,
            role,
            &timestamp_suffix(timestamp),
            blocks,
            filter_lower,
            tool_name_filter,
        );
        return;
    }
    if let Some(text) = content.as_str() {
        dump_text_content(
            index,
            role,
            &timestamp_suffix(timestamp),
            text,
            filter_lower,
        );
    }
}

/// Format a content block for dump output.
pub(super) fn format_dump_block(index: usize, role: &str, block: &serde_json::Value) -> DumpBlock {
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

/// Format a `tool_use` block for dump output.
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

pub(super) fn timestamp_suffix(timestamp: &str) -> String {
    if timestamp.is_empty() {
        String::new()
    } else {
        format!(" {timestamp}")
    }
}

fn should_dump_text(text: &str, filter_lower: Option<&str>) -> bool {
    text.len() > MIN_DUMP_TEXT_LENGTH && matches_dump_filter(&text.to_lowercase(), filter_lower)
}

fn print_dump_line(label: &str, ts_suffix: &str, text: &str) {
    let truncated = truncate_at(text, DUMP_TRUNCATE_LENGTH);
    println!("{label}{ts_suffix}: {truncated}");
}

fn dump_content_blocks(
    index: usize,
    role: &str,
    ts_suffix: &str,
    blocks: &[serde_json::Value],
    filter_lower: Option<&str>,
    tool_name_filter: Option<&str>,
) {
    for block in blocks {
        if !passes_tool_name_filter(block, tool_name_filter) {
            continue;
        }
        let db = format_dump_block(index, role, block);
        if should_dump_text(&db.text, filter_lower) {
            print_dump_line(&db.label, ts_suffix, &db.text);
        }
    }
}

fn dump_text_content(
    index: usize,
    role: &str,
    ts_suffix: &str,
    text: &str,
    filter_lower: Option<&str>,
) {
    if !should_dump_text(text, filter_lower) {
        return;
    }
    let label = format!("L{index} [{role}]");
    print_dump_line(&label, ts_suffix, text);
}
