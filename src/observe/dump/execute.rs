use std::fs;
use std::io::{BufRead, BufReader};

use crate::errors::{CliError, CliErrorKind};

use super::super::session;
use super::super::{DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, truncate_at};
use super::{DumpOptions, format_dump_block, timestamp_suffix};

/// Parsed fields from a valid dump JSONL line.
struct ParsedDumpLine<'a> {
    role: &'a str,
    timestamp: &'a str,
    message: &'a serde_json::Value,
}

/// Execute dump mode - raw event stream without classification.
pub(crate) fn execute_dump(
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

fn matches_dump_filter(text_lower: &str, filter_lower: Option<&str>) -> bool {
    filter_lower.is_none_or(|f| text_lower.contains(f))
}

fn passes_tool_name_filter(block: &serde_json::Value, filter: Option<&str>) -> bool {
    let Some(name_filter) = filter else {
        return true;
    };
    let block_type = block["type"].as_str().unwrap_or("");
    if block_type == "tool_use" {
        let name = block["name"].as_str().unwrap_or("");
        return name.eq_ignore_ascii_case(name_filter);
    }
    block_type != "tool_result"
}

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
