mod emitter;
pub mod registry;
mod rules;
mod text_checks;
mod tool_checks;

#[cfg(test)]
mod tests;

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;

use self::emitter::{IssueBlueprint, IssueEmitter};
use super::types::{Issue, IssueCategory, MessageRole, ScanState, SourceTool};
use crate::observe::application::session_event::{
    SessionContent, SessionContentBlock, parse_session_event,
};
use crate::observe::dump::tool_result_text;

pub use tool_checks::check_tool_use_for_issues;

/// Minimum text length to bother classifying.
const MIN_TEXT_LENGTH: usize = 5;

static EXIT_CODE_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"exit code (\d+)|exit: (\d+)").expect("valid regex"));
static AGENT_NAME_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"Agent "([^"]+)""#).expect("valid regex"));
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
fn resolve_source_tool(block: &serde_json::Value, state: &ScanState) -> Option<SourceTool> {
    let tool_id = block["tool_use_id"].as_str()?;
    let record = state.last_tool_uses.get(tool_id)?;
    SourceTool::from_label(&record.tool.original_name)
}

// ─── Context struct ────────────────────────────────────────────────

/// Shared context passed to all text classification functions.
pub(super) struct TextCheckContext<'a> {
    pub line_number: usize,
    pub role: MessageRole,
    pub text: &'a str,
    pub lower: &'a str,
    pub matched_categories: HashSet<IssueCategory>,
    pub source_tool: Option<SourceTool>,
    pub state: &'a mut ScanState,
}

impl TextCheckContext<'_> {
    fn emit_current(&mut self, issues: &mut Vec<Issue>, blueprint: IssueBlueprint) -> bool {
        self.emit_details(issues, blueprint, self.text)
    }

    fn emit_details(
        &mut self,
        issues: &mut Vec<Issue>,
        blueprint: IssueBlueprint,
        details: &str,
    ) -> bool {
        IssueEmitter::new(self.line_number, self.role, self.state).emit(issues, blueprint, details)
    }
}

type TextCheckFn = fn(&mut TextCheckContext<'_>, &mut Vec<Issue>);

const BASH_TEXT_CHECKS: &[TextCheckFn] = &[
    text_checks::check_ksa_codes,
    text_checks::check_exit_code_issues,
    text_checks::check_env_misconfiguration,
    text_checks::check_jq_errors,
    text_checks::check_closeout_verdict_pending,
    text_checks::check_runner_state_event_error,
    text_checks::check_runner_state_machine_stale,
];

const USER_TEXT_CHECKS: &[TextCheckFn] = &[
    text_checks::check_permission_failures,
    text_checks::check_user_frustration,
];

const ASSISTANT_TEXT_CHECKS: &[TextCheckFn] = &[
    text_checks::check_save_failures,
    text_checks::check_payload_recovery,
    text_checks::check_incomplete_writer,
    text_checks::check_harness_infrastructure,
    text_checks::check_missing_connection_or_env_var,
];

const COORDINATION_TEXT_CHECKS: &[TextCheckFn] = &[
    text_checks::coordination::check_api_rate_limit,
    text_checks::coordination::check_guard_denial_loop,
];

fn run_text_checks(
    checks: &[TextCheckFn],
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    for check in checks {
        check(context, issues);
    }
}

// ─── Public API ────────────────────────────────────────────────────

/// Classify text content for issues.
///
/// `source_tool` is the tool that produced this text - `None` for
/// assistant/human text blocks.
pub fn check_text_for_issues(
    line_num: usize,
    role: MessageRole,
    text: &str,
    source_tool: Option<SourceTool>,
    state: &mut ScanState,
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
        rules::apply_text_rules(line_num, role, text, &lower, source_tool, state);

    let mut context = TextCheckContext {
        line_number: line_num,
        role,
        text,
        lower: &lower,
        matched_categories,
        source_tool,
        state,
    };

    // Complex standalone checks grouped by role/tool guard so each check
    // doesn't repeat the same filtering.
    if source_tool == Some(SourceTool::Bash) {
        run_text_checks(BASH_TEXT_CHECKS, &mut context, &mut issues);
    }

    if role == MessageRole::User && source_tool.is_none() {
        run_text_checks(USER_TEXT_CHECKS, &mut context, &mut issues);
    }

    if role == MessageRole::Assistant && source_tool.is_none() {
        run_text_checks(ASSISTANT_TEXT_CHECKS, &mut context, &mut issues);
    }

    if context.state.agent_id.is_some() || context.state.orchestration_session_id.is_some() {
        run_text_checks(COORDINATION_TEXT_CHECKS, &mut context, &mut issues);
    }

    issues
}

/// Classify a single JSONL line from a session log.
///
/// Parses the JSON, dispatches to text/`tool_use` checkers, and deduplicates.
pub fn classify_line(line_num: usize, raw: &str, state: &mut ScanState) -> Vec<Issue> {
    let Some(event) = parse_session_event(raw) else {
        return Vec::new();
    };

    if state.session_start_timestamp.is_none()
        && let Some(ts) = &event.timestamp
    {
        state.session_start_timestamp = Some(ts.clone());
    }

    let Some(role) = MessageRole::from_label(&event.message.role) else {
        return Vec::new();
    };
    let mut issues = Vec::new();

    match event.message.content {
        SessionContent::Blocks(blocks) => {
            classify_content_blocks(line_num, role, &blocks, state, &mut issues);
        }
        SessionContent::Text(text) if text.len() > MIN_TEXT_LENGTH => {
            issues.extend(check_text_for_issues(line_num, role, &text, None, state));
        }
        SessionContent::Text(_) => {}
    }

    issues
}

/// Process content blocks from a message.
fn classify_content_blocks(
    line_num: usize,
    role: MessageRole,
    blocks: &[SessionContentBlock],
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    for block in blocks {
        match block {
            SessionContentBlock::Text(text) => {
                if text.len() > MIN_TEXT_LENGTH {
                    issues.extend(check_text_for_issues(line_num, role, text, None, state));
                }
            }
            SessionContentBlock::ToolUse(block) => {
                issues.extend(check_tool_use_for_issues(line_num, block, state));
            }
            SessionContentBlock::ToolResult(block) => {
                let text = tool_result_text(block);
                if text.len() > MIN_TEXT_LENGTH {
                    let source = resolve_source_tool(block, state);
                    issues.extend(check_text_for_issues(line_num, role, &text, source, state));
                }
            }
            SessionContentBlock::Other => {}
        }
    }
}
