mod issue_builder;
mod rules;
mod text_checks;
mod tool_checks;

#[cfg(test)]
mod tests;

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use super::tool_result_text;
use super::types::{Issue, IssueCategory, MessageRole, ScanState, SourceTool};

pub use tool_checks::check_tool_use_for_issues;

/// Minimum text length to bother classifying.
const MIN_TEXT_LENGTH: usize = 5;

static EXIT_CODE_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"exit code (\d+)|exit: (\d+)").expect("valid regex"));
static AGENT_NAME_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"Agent "([^"]+)""#).expect("valid regex"));
static OLD_SKILL_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"--skill\s+(suite-author|suite-runner)\b").expect("valid regex"));
static RM_RECURSIVE_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\brm\s+(-\w+\s+)*.*-r").expect("valid regex"));
static SKILL_NAME_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^name:\s*(\S+)").expect("valid regex"));

// ─── Heuristic guards ──────────────────────────────────────────────

/// Heuristic: text from the Read tool has line-numbered format.
fn is_file_content(text: &str) -> bool {
    let numbered = text
        .lines()
        .take(5)
        .filter(|line| {
            let trimmed = line.trim_start();
            trimmed.chars().next().is_some_and(|c| c.is_ascii_digit())
                && trimmed.contains('\u{2192}')
        })
        .count();
    numbered >= 2
}

/// Detect harness `--help` output (success, not error).
fn is_help_output(text: &str) -> bool {
    // Only need to check the prefix - no need to lowercase the entire text.
    let end = text.floor_char_boundary(text.len().min(200));
    let lower = text[..end].to_lowercase();
    let trimmed = lower.trim();
    trimmed.starts_with("kuma test harness")
        || (trimmed.starts_with("usage: harness") && !trimmed.contains("error:"))
        || trimmed.starts_with("handle session start hook\n\nusage:")
}

/// Detect compaction context injection.
fn is_compaction_summary(text: &str) -> bool {
    let end = text.floor_char_boundary(text.len().min(200));
    text[..end]
        .to_lowercase()
        .contains("this session is being continued from a previous conversation")
}

/// Detect skill content injected by Claude Code when a skill is loaded.
fn is_skill_injection(text: &str) -> bool {
    text.trim().starts_with("Base directory for this skill:")
}

/// Figure out which tool produced a `tool_result` block.
fn resolve_source_tool(block: &Value, state: &ScanState) -> Option<SourceTool> {
    let tool_id = block["tool_use_id"].as_str()?;
    let record = state.last_tool_uses.get(tool_id)?;
    SourceTool::from_label(&record.name)
}

/// Regex that replaces all digit sequences with `#` for dedup normalization.
/// This makes "exit code 1" and "exit code 137" produce the same key.
static DEDUP_NORMALIZE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\d+").expect("valid regex"));

/// Build a normalized dedup key from an issue.
fn dedup_key(issue: &Issue) -> (IssueCategory, String) {
    let normalized = DEDUP_NORMALIZE.replace_all(&issue.summary, "#");
    (issue.category, normalized.into_owned())
}

/// Return true if this issue is a duplicate that should be skipped.
fn dedup_issue(issue: &Issue, state: &mut ScanState) -> bool {
    let key = dedup_key(issue);
    if state.seen_issues.contains(&key) {
        return true;
    }
    state.seen_issues.insert(key);
    false
}

// ─── Context struct ────────────────────────────────────────────────

/// Shared context passed to all text classification functions.
pub(super) struct TextCheckContext<'a> {
    pub line_number: usize,
    pub role: MessageRole,
    pub text: &'a str,
    pub lower: &'a str,
    pub source_tool: Option<SourceTool>,
    pub matched_categories: HashSet<IssueCategory>,
}

// ─── Public API ────────────────────────────────────────────────────

/// Classify text content for issues.
///
/// `source_tool` is the tool that produced this text - `None` for
/// assistant/human text blocks.
#[must_use]
pub fn check_text_for_issues(
    line_num: usize,
    role: MessageRole,
    text: &str,
    source_tool: Option<SourceTool>,
) -> Vec<Issue> {
    if source_tool == Some(SourceTool::Read) || is_file_content(text) {
        return Vec::new();
    }
    if is_help_output(text) || is_compaction_summary(text) || is_skill_injection(text) {
        return Vec::new();
    }

    let lower = text.to_lowercase();

    // Rule table handles the 15 simple pattern-matching checks.
    let (mut issues, matched_categories) =
        rules::apply_text_rules(line_num, role, text, &lower, source_tool);

    let context = TextCheckContext {
        line_number: line_num,
        role,
        text,
        lower: &lower,
        source_tool,
        matched_categories,
    };

    // Complex standalone checks that need regex, multi-branch, or dynamic formatting.
    text_checks::check_ksa_codes(&context, &mut issues);
    text_checks::check_exit_code_issues(&context, &mut issues);
    text_checks::check_permission_failures(&context, &mut issues);
    text_checks::check_save_failures(&context, &mut issues);
    text_checks::check_payload_recovery(&context, &mut issues);
    text_checks::check_env_misconfiguration(&context, &mut issues);
    text_checks::check_incomplete_writer(&context, &mut issues);
    text_checks::check_user_frustration(&context, &mut issues);

    issues
}

/// Classify a single JSONL line from a session log.
///
/// Parses the JSON, dispatches to text/`tool_use` checkers, and deduplicates.
pub fn classify_line(line_num: usize, raw: &str, state: &mut ScanState) -> Vec<Issue> {
    let obj: Value = match serde_json::from_str(raw.trim()) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };

    if state.session_start_timestamp.is_none()
        && let Some(ts) = obj["timestamp"].as_str()
    {
        state.session_start_timestamp = Some(ts.to_string());
    }

    let message = &obj["message"];
    if !message.is_object() {
        return Vec::new();
    }

    let role_str = message["role"].as_str().unwrap_or("");
    let Some(role) = MessageRole::from_label(role_str) else {
        return Vec::new();
    };

    let content = &message["content"];
    let mut issues = Vec::new();

    if let Some(blocks) = content.as_array() {
        classify_content_blocks(line_num, role, blocks, state, &mut issues);
    } else if let Some(text) = content.as_str()
        && text.len() > MIN_TEXT_LENGTH
    {
        issues.extend(check_text_for_issues(line_num, role, text, None));
    }

    issues.retain(|issue| !dedup_issue(issue, state));
    issues
}

/// Process content blocks from a message.
fn classify_content_blocks(
    line_num: usize,
    role: MessageRole,
    blocks: &[Value],
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    for block in blocks {
        let block_type = block["type"].as_str().unwrap_or("");
        match block_type {
            "text" => {
                let text = block["text"].as_str().unwrap_or("");
                if text.len() > MIN_TEXT_LENGTH {
                    issues.extend(check_text_for_issues(line_num, role, text, None));
                }
            }
            "tool_use" => {
                issues.extend(check_tool_use_for_issues(line_num, block, state));
            }
            "tool_result" => {
                let text = tool_result_text(block);
                if text.len() > MIN_TEXT_LENGTH {
                    let source = resolve_source_tool(block, state);
                    issues.extend(check_text_for_issues(line_num, role, &text, source));
                }
            }
            _ => {}
        }
    }
}
