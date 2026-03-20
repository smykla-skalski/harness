mod bash;
mod lifecycle;
mod questions;
mod write_checks;

use serde_json::Value;

use self::bash::check_bash_tool_use;
use self::lifecycle::check_uncommitted_source_code_edit;
use self::questions::check_ask_user_question;
use self::write_checks::{
    check_managed_file_writes, check_manifest_created_during_run, check_write_edit_tool_use,
};
use crate::kernel::tooling::{ToolContext, legacy_tool_context};
use crate::observe::types::{Issue, ScanState, ToolUseRecord};

/// Check a `tool_use` block for issues.
pub fn check_tool_use_for_issues(
    line_num: usize,
    block: &Value,
    state: &mut ScanState,
) -> Vec<Issue> {
    let mut issues = Vec::new();
    let name = block["name"].as_str().unwrap_or("");
    let input = &block["input"];
    let tool = legacy_tool_context(name, input.clone(), None);

    if matches!(name, "Write" | "Edit" | "Bash") {
        check_uncommitted_source_code_edit(line_num, name, input, state, &mut issues);
    }

    if name == "Bash" {
        check_bash_tool_use(line_num, &tool.input, state, &mut issues);
    }

    if name == "AskUserQuestion" {
        check_ask_user_question(line_num, input, state, &mut issues);
    }

    if matches!(name, "Write" | "Edit") {
        check_write_edit_tool_use(line_num, name, input, state, &mut issues);
        check_managed_file_writes(line_num, input, state, &mut issues);
        check_manifest_created_during_run(line_num, input, state, &mut issues);
    }

    record_tool_use(block, tool, state);
    issues
}

fn record_tool_use(block: &Value, tool: ToolContext, state: &mut ScanState) {
    if let Some(tool_id) = block["id"].as_str()
        && !tool_id.is_empty()
    {
        state
            .last_tool_uses
            .insert(tool_id.to_string(), ToolUseRecord { tool });
    }
}

#[cfg(test)]
pub(super) fn extract_kubectl_query_target(command: &str) -> Option<String> {
    bash::extract_kubectl_query_target(command)
}
