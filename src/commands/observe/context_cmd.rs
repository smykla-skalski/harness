use std::fs;
use std::io::{BufRead, BufReader};

use crate::errors::{CliError, CliErrorKind};

use super::dump::{format_dump_block, timestamp_suffix};
use super::session;
use super::{DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, truncate_at};

/// Render a single line of context output from a parsed JSONL event.
fn render_context_line(index: usize, target_line: usize, obj: &serde_json::Value) {
    let message = &obj["message"];
    if !message.is_object() {
        return;
    }
    let role = message["role"].as_str().unwrap_or("");
    let prefix = if index == target_line { ">>> " } else { "    " };
    let ts_part = timestamp_suffix(obj["timestamp"].as_str().unwrap_or(""));

    if let Some(blocks) = message["content"].as_array() {
        render_context_blocks(index, role, prefix, &ts_part, blocks);
        return;
    }
    if let Some(text) = message["content"].as_str() {
        render_context_text(index, role, prefix, &ts_part, text);
    }
}

fn render_context_blocks(
    index: usize,
    role: &str,
    prefix: &str,
    ts_part: &str,
    blocks: &[serde_json::Value],
) {
    for block in blocks {
        let db = format_dump_block(index, role, block);
        if db.text.len() <= MIN_DUMP_TEXT_LENGTH {
            continue;
        }
        let truncated = truncate_at(&db.text, DUMP_TRUNCATE_LENGTH);
        println!("{prefix}{}{ts_part}: {truncated}", db.label);
    }
}

fn render_context_text(index: usize, role: &str, prefix: &str, ts_part: &str, text: &str) {
    if text.len() <= MIN_DUMP_TEXT_LENGTH {
        return;
    }
    let truncated = truncate_at(text, DUMP_TRUNCATE_LENGTH);
    println!("{prefix}L{index} [{role}]{ts_part}: {truncated}");
}

/// Execute context mode - show events around a specific line.
pub(super) fn execute_context(
    session_id: &str,
    target_line: usize,
    window: usize,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let start = target_line.saturating_sub(window);
    let end = target_line + window;
    let path = session::find_session(session_id, project_hint)?;
    let file = fs::File::open(&path)
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot open session file: {e}")))?;
    let reader = BufReader::new(file);

    for (index, line_result) in reader.lines().enumerate() {
        if index < start {
            continue;
        }
        if index > end {
            break;
        }
        let Ok(line) = line_result else { continue };
        let Ok(obj) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            continue;
        };
        render_context_line(index, target_line, &obj);
    }
    Ok(0)
}
