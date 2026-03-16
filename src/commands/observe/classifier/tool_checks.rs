use serde_json::Value;

use super::{OLD_SKILL_REGEX, RM_RECURSIVE_REGEX, SKILL_NAME_REGEX};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{
    Issue, IssueCategory, IssueSeverity, MessageRole, ScanState, ToolUseRecord,
};

/// Check a `tool_use` block for issues.
pub fn check_tool_use_for_issues(
    line_num: usize,
    block: &Value,
    state: &mut ScanState,
) -> Vec<Issue> {
    let mut issues = Vec::new();
    let name = block["name"].as_str().unwrap_or("");
    let input = &block["input"];

    if name == "Bash" {
        check_bash_tool_use(line_num, input, &mut issues);
    }

    if name == "AskUserQuestion" {
        check_ask_user_question(line_num, input, &mut issues);
    }

    if name == "Write" || name == "Edit" {
        check_write_edit_tool_use(line_num, name, input, state, &mut issues);
        check_managed_file_writes(line_num, input, &mut issues);
    }

    // Record tool_use for correlating with tool_result.
    if let Some(tool_id) = block["id"].as_str()
        && !tool_id.is_empty()
    {
        state.last_tool_uses.insert(
            tool_id.to_string(),
            ToolUseRecord {
                name: name.to_string(),
                input: input.clone(),
            },
        );
    }

    issues
}

// ─── tool_use sub-checks ───────────────────────────────────────────

/// Check Bash `tool_use` for specific patterns.
fn check_bash_tool_use(line_num: usize, input: &Value, issues: &mut Vec<Issue>) {
    let command = input["command"].as_str().unwrap_or("");

    if OLD_SKILL_REGEX.is_match(command) {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::NamingError,
            severity: IssueSeverity::Medium,
            summary: "Old skill name used in harness command".into(),
            details: format!("Command: {command}"),
            source_role: MessageRole::Assistant,
            fixable: true,
            fix_target: None,
            fix_hint: Some("SKILL.md or model still references old skill names".into()),
        });
    }

    if command.contains("harness") && command.contains("validator-decision") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::CliError,
            severity: IssueSeverity::Medium,
            summary: "Invalid harness subcommand/argument used".into(),
            details: format!("Command: {command}"),
            source_role: MessageRole::Assistant,
            fixable: true,
            fix_target: None,
            fix_hint: Some("SKILL.md references a non-existent harness kind".into()),
        });
    }

    let command_lower = command.to_lowercase();
    if patterns::PYTHON_USAGE_SIGNALS
        .iter()
        .any(|signal| command_lower.contains(signal))
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: "Python used in Bash command - agents should never need python".into(),
            details: format!("Command: {command}"),
            source_role: MessageRole::Assistant,
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "Use harness commands or shell builtins instead of python one-liners".into(),
            ),
        });
    }

    if RM_RECURSIVE_REGEX.is_match(command) && !command.contains("&&") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: "Destructive rm -r without chained verification".into(),
            details: format!("Command: {command}"),
            source_role: MessageRole::Assistant,
            fixable: false,
            fix_target: None,
            fix_hint: Some("Should verify target exists and is correct before deleting".into()),
        });
    }
}

/// Check `AskUserQuestion` `tool_use` for issue patterns.
fn check_ask_user_question(line_num: usize, input: &Value, issues: &mut Vec<Issue>) {
    let Some(questions) = input["questions"].as_array() else {
        return;
    };

    for question_block in questions {
        let question_text = question_block["question"].as_str().unwrap_or("");
        let question_lower = question_text.to_lowercase();
        let options = question_block["options"].as_array();
        let header = question_block["header"].as_str().unwrap_or("");

        check_manifest_fix_prompt(line_num, question_text, &question_lower, issues);
        check_validator_install_prompt(line_num, question_text, &question_lower, issues);
        check_question_deviations(
            line_num,
            question_text,
            &question_lower,
            header,
            options,
            issues,
        );
        check_wrong_skill_crossref(line_num, question_text, &question_lower, options, issues);
    }
}

/// Check for manifest-fix prompt in a question.
fn check_manifest_fix_prompt(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("manifest-fix") && question_lower.contains("how should this failure")
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::DataIntegrity,
            severity: IssueSeverity::Medium,
            summary: "Manifest rejected by cluster - possible product bug".into(),
            details: format!("Question: {question_text}"),
            source_role: MessageRole::Assistant,
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "CRD or webhook rejected a manifest. Could be a suite error OR a product bug. \
                 Investigate whether the Go validator accepts what the CRD rejects."
                    .into(),
            ),
        });
    }
}

/// Check for `kubectl-validate` install prompt.
fn check_validator_install_prompt(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("kubectl-validate") && question_lower.contains("install") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Medium,
            summary: "Validator install prompt when binary may already exist".into(),
            details: format!("Question: {question_text}"),
            source_role: MessageRole::Assistant,
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some("Step 0 should check if binary exists first".into()),
        });
    }
}

/// Check for runtime deviation signals in a question's full text.
/// Short-circuits per part rather than joining into one big string.
fn check_question_deviations(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    header: &str,
    options: Option<&Vec<Value>>,
    issues: &mut Vec<Issue>,
) {
    let has_signal = |text: &str| -> bool {
        patterns::QUESTION_DEVIATION_SIGNALS
            .iter()
            .any(|signal| text.contains(signal))
    };

    let header_lower = header.to_lowercase();
    let found = has_signal(&header_lower)
        || has_signal(question_lower)
        || options.is_some_and(|opts| {
            opts.iter().any(|opt| {
                opt["label"]
                    .as_str()
                    .is_some_and(|s| has_signal(&s.to_lowercase()))
                    || opt["description"]
                        .as_str()
                        .is_some_and(|s| has_signal(&s.to_lowercase()))
                    || opt.as_str().is_some_and(|s| has_signal(&s.to_lowercase()))
            })
        });

    if found {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Critical,
            summary: "Runtime deviation - authored suite needs runtime correction".into(),
            details: format!("Header: {header}, Question: {question_text}"),
            source_role: MessageRole::Assistant,
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some(
                "suite:new should produce suites that don't require runtime deviations".into(),
            ),
        });
    }
}

/// Check for wrong skill cross-references in question options.
fn check_wrong_skill_crossref(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    options: Option<&Vec<Value>>,
    issues: &mut Vec<Issue>,
) {
    let Some(opts) = options else {
        return;
    };
    for opt in opts {
        let label = opt["label"].as_str().or_else(|| opt.as_str()).unwrap_or("");
        if label.to_lowercase().contains("suite:new") && question_lower.contains("suite:run") {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::SkillBehavior,
                severity: IssueSeverity::Medium,
                summary: "suite:run offering suite:new as structured choice".into(),
                details: format!("Question: {question_text}, Option: {label}"),
                source_role: MessageRole::Assistant,
                fixable: true,
                fix_target: Some("skills/run/SKILL.md".into()),
                fix_hint: Some(
                    "suite:run should not offer suite:new as a structured option".into(),
                ),
            });
        }
    }
}

/// Check Write/Edit `tool_use` for churn and naming issues.
fn check_write_edit_tool_use(
    line_num: usize,
    tool_name: &str,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let path = input["file_path"].as_str().unwrap_or("");

    let count = state.edit_counts.entry(path.to_string()).or_insert(0);
    *count += 1;

    if *count == 10 || *count == 20 {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: format!("File modified {} times - possible churn", *count),
            details: format!("Path: {path}"),
            source_role: MessageRole::Assistant,
            fixable: false,
            fix_target: None,
            fix_hint: Some("Repeated modifications suggest trial-and-error".into()),
        });
    }

    if path.contains("SKILL.md") {
        let content = if tool_name == "Write" {
            input["content"].as_str().unwrap_or("")
        } else {
            input["new_string"].as_str().unwrap_or("")
        };
        if let Some(captures) = SKILL_NAME_REGEX.captures(content) {
            let skill_name = captures.get(1).map_or("", |m| m.as_str());
            if matches!(skill_name, "new" | "run" | "observe") && !skill_name.contains(':') {
                issues.push(Issue {
                    line: line_num,
                    category: IssueCategory::SkillBehavior,
                    severity: IssueSeverity::Critical,
                    summary: format!(
                        "SKILL.md name field uses short name '{skill_name}' instead of fully qualified"
                    ),
                    details: format!("Path: {path}, name: {skill_name}"),
                    source_role: MessageRole::Assistant,
                    fixable: true,
                    fix_target: Some(path.to_string()),
                    fix_hint: Some(
                        "Name should be fully qualified like 'suite:new' or 'suite:run'".into(),
                    ),
                });
            }
        }
    }
}

/// Check for direct writes to harness-managed files via Write/Edit tools.
fn check_managed_file_writes(line_num: usize, input: &Value, issues: &mut Vec<Issue>) {
    let path = input["file_path"].as_str().unwrap_or("");
    let path_lower = path.to_lowercase();
    for managed in patterns::MANAGED_CONTEXT_FILES {
        if path_lower.contains(managed) {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::UnexpectedBehavior,
                severity: IssueSeverity::Critical,
                summary: format!("Direct write to harness-managed file: {managed}"),
                details: format!("Path: {path}"),
                source_role: MessageRole::Assistant,
                fixable: true,
                fix_target: Some("skills/run/SKILL.md".into()),
                fix_hint: Some(
                    "Use harness commands to update managed files, not direct Write/Edit".into(),
                ),
            });
            break;
        }
    }
}
