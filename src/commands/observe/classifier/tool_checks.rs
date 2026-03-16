use serde_json::Value;

use super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use super::{OLD_SKILL_REGEX, RM_RECURSIVE_REGEX, SKILL_NAME_REGEX};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{
    Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole, ScanState, ToolUseRecord,
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
        check_bash_tool_use(line_num, input, state, &mut issues);
    }

    if name == "AskUserQuestion" {
        check_ask_user_question(line_num, input, state, &mut issues);
    }

    if name == "Write" || name == "Edit" {
        check_write_edit_tool_use(line_num, name, input, state, &mut issues);
        check_managed_file_writes(line_num, input, state, &mut issues);
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
fn check_bash_tool_use(
    line_num: usize,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let command = input["command"].as_str().unwrap_or("");
    let details = format!("Command: {command}");
    let mut emitter = IssueEmitter::new(line_num, MessageRole::Assistant, state);

    if OLD_SKILL_REGEX.is_match(command) {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::OldSkillNameUsedInCommand,
                IssueCategory::NamingError,
                IssueSeverity::Medium,
                "Old skill name used in harness command",
            )
            .with_guidance(Guidance::fix_hint(
                "SKILL.md or model still references old skill names",
            )),
            &details,
        );
    }

    if command.contains("harness") && command.contains("validator-decision") {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::InvalidHarnessSubcommandUsed,
                IssueCategory::CliError,
                IssueSeverity::Medium,
                "Invalid harness subcommand/argument used",
            )
            .with_guidance(Guidance::fix_hint(
                "SKILL.md references a non-existent harness kind",
            )),
            &details,
        );
    }

    let command_lower = command.to_lowercase();
    if patterns::PYTHON_USAGE_SIGNALS
        .iter()
        .any(|signal| command_lower.contains(signal))
    {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::PythonUsedInBashToolUse,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Medium,
                "Python used in Bash command - agents should never need python",
            )
            .with_guidance(Guidance::fix_hint(
                "Use harness commands or shell builtins instead of python one-liners",
            )),
            &details,
        );
    }

    if RM_RECURSIVE_REGEX.is_match(command) && !command.contains("&&") {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::UnverifiedRecursiveRemove,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Medium,
                "Destructive rm -r without chained verification",
            )
            .with_guidance(Guidance::advisory(
                "Should verify target exists and is correct before deleting",
            )),
            &details,
        );
    }

    if command.contains("make k3d/") || command.contains("make kind/") {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::RawClusterMakeTargetUsed,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Critical,
                "Raw make target used for cluster operation",
            )
            .with_guidance(Guidance::fix_hint(
                "Use harness cluster instead of raw make targets",
            )),
            &details,
        );
    }

    if command.contains("git commit") || command.contains("git add") {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::UnauthorizedGitCommitDuringRun,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Critical,
                "Unauthorized git commit during active run",
            )
            .with_guidance(Guidance::fix_hint(
                "Agent committed code without asking the user via bug-found gate",
            )),
            &details,
        );
    }

    check_absolute_manifest_path(command, &details, &mut emitter, issues);
    check_direct_task_output_read(command, &details, &mut emitter, issues);
    check_env_var_construction(command, &details, &mut emitter, issues);
}

/// Detect `harness apply --manifest /absolute/path` usage.
///
/// Harness resolves manifest paths relative to the suite directory automatically.
/// Using absolute paths is unnecessary and fragile - relative paths like
/// `g13/01.yaml` are the expected convention.
fn check_absolute_manifest_path(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if !command.contains("harness") || !command.contains("apply") {
        return;
    }

    // Look for `--manifest /...` anywhere in the command. The path token
    // immediately after `--manifest` starts with `/` when absolute.
    let mut tokens = command.split_whitespace().peekable();
    while let Some(token) = tokens.next() {
        if token == "--manifest"
            && let Some(path) = tokens.peek()
            && path.starts_with('/')
        {
            emitter.emit(
                issues,
                IssueBlueprint::new(
                    IssueCode::AbsoluteManifestPathUsed,
                    IssueCategory::UnexpectedBehavior,
                    IssueSeverity::Medium,
                    "Absolute path used with harness apply",
                )
                .with_guidance(Guidance::fix_hint(
                    "Use relative manifest paths (e.g. g13/01.yaml). \
                     Harness resolves them from the suite directory.",
                )),
                details,
            );
            return;
        }
    }
}

/// Detect direct reads of Claude's internal task output files.
///
/// Agents sometimes bypass `TaskOutput` by reading `/private/tmp/claude-501/.../tasks/*.output`
/// directly, or polling with `sleep && cat`. Both patterns skip harness tracking.
fn check_direct_task_output_read(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    let is_task_file_read = command.contains("/private/tmp/claude-501/")
        && (command.contains("tasks/") || command.contains(".output"));
    let is_polling_pattern =
        command.contains("sleep") && command.contains("cat") && command.contains("tasks/");

    if is_task_file_read || is_polling_pattern {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::DirectTaskOutputFileRead,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Medium,
                "Direct read of internal task output file",
            )
            .with_guidance(Guidance::fix_hint(
                "Use TaskOutput tool instead of reading task files directly",
            )),
            details,
        );
    }
}

/// Detect env var prefixes and export statements in Bash commands.
///
/// The guard-bash hook strips `VAR=value` prefixes to find the real command
/// head, but the observer needs to flag these patterns too - agents should
/// not be constructing environment manually since harness handles it.
fn check_env_var_construction(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    // KUBECONFIG= is a specific, higher-signal pattern
    if command.contains("KUBECONFIG=") {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::ManualKubeconfigConstruction,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Medium,
                "Agent manually setting KUBECONFIG",
            )
            .with_guidance(Guidance::fix_hint(
                "Agent manually setting KUBECONFIG. Harness injects it automatically.",
            )),
            details,
        );
        return;
    }

    // Generic: `export FOO=bar` or `FOO=bar command` prefix patterns
    if command.starts_with("export ") && command.contains('=') {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::ManualExportConstruction,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Medium,
                "Agent constructing env vars via export",
            )
            .with_guidance(Guidance::fix_hint(
                "Agent constructing env vars. Harness handles environment automatically.",
            )),
            details,
        );
        return;
    }

    // `VAR=value command` prefix: first token looks like an env assignment
    // and there is at least one more token after it.
    if let Some(first_space) = command.find(' ') {
        let first_token = &command[..first_space];
        if is_env_assignment(first_token) {
            emitter.emit(
                issues,
                IssueBlueprint::new(
                    IssueCode::ManualEnvPrefixConstruction,
                    IssueCategory::UnexpectedBehavior,
                    IssueSeverity::Medium,
                    "Agent constructing env var prefix",
                )
                .with_guidance(Guidance::fix_hint(
                    "Agent constructing env vars. Harness handles environment automatically.",
                )),
                details,
            );
        }
    }
}

/// Check if a token is a `VAR=value` env assignment.
fn is_env_assignment(token: &str) -> bool {
    let Some(eq_pos) = token.find('=') else {
        return false;
    };
    if eq_pos == 0 {
        return false;
    }
    let prefix = &token[..eq_pos];
    prefix
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_')
        && prefix
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
}

/// Check `AskUserQuestion` `tool_use` for issue patterns.
fn check_ask_user_question(
    line_num: usize,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let Some(questions) = input["questions"].as_array() else {
        return;
    };
    let mut emitter = IssueEmitter::new(line_num, MessageRole::Assistant, state);

    for question_block in questions {
        let question_text = question_block["question"].as_str().unwrap_or("");
        let question_lower = question_text.to_lowercase();
        let options = question_block["options"].as_array();
        let header = question_block["header"].as_str().unwrap_or("");

        check_manifest_fix_prompt(question_text, &question_lower, &mut emitter, issues);
        check_validator_install_prompt(question_text, &question_lower, &mut emitter, issues);
        check_question_deviations(
            question_text,
            &question_lower,
            header,
            options,
            &mut emitter,
            issues,
        );
        check_wrong_skill_crossref(
            question_text,
            &question_lower,
            options,
            &mut emitter,
            issues,
        );
    }
}

/// Check for manifest-fix prompt in a question.
fn check_manifest_fix_prompt(
    question_text: &str,
    question_lower: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("manifest-fix") && question_lower.contains("how should this failure")
    {
        let details = format!("Question: {question_text}");
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::ManifestFixPromptShown,
                IssueCategory::DataIntegrity,
                IssueSeverity::Medium,
                "Manifest rejected by cluster - possible product bug",
            )
            .with_guidance(Guidance::fix_hint(
                "CRD or webhook rejected a manifest. Could be a suite error OR a product bug. \
                 Investigate whether the Go validator accepts what the CRD rejects.",
            )),
            &details,
        );
    }
}

/// Check for `kubectl-validate` install prompt.
fn check_validator_install_prompt(
    question_text: &str,
    question_lower: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("kubectl-validate") && question_lower.contains("install") {
        let details = format!("Question: {question_text}");
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::ValidatorInstallPromptShown,
                IssueCategory::SkillBehavior,
                IssueSeverity::Medium,
                "Validator install prompt when binary may already exist",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/new/SKILL.md",
                "Step 0 should check if binary exists first",
            )),
            &details,
        );
    }
}

/// Check for runtime deviation signals in a question's full text.
/// Short-circuits per part rather than joining into one big string.
fn check_question_deviations(
    question_text: &str,
    question_lower: &str,
    header: &str,
    options: Option<&Vec<Value>>,
    emitter: &mut IssueEmitter<'_>,
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
        let details = format!("Header: {header}, Question: {question_text}");
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::RuntimeDeviationPromptShown,
                IssueCategory::SkillBehavior,
                IssueSeverity::Critical,
                "Runtime deviation - authored suite needs runtime correction",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/new/SKILL.md",
                "suite:new should produce suites that don't require runtime deviations",
            )),
            &details,
        );
    }
}

/// Check for wrong skill cross-references in question options.
fn check_wrong_skill_crossref(
    question_text: &str,
    question_lower: &str,
    options: Option<&Vec<Value>>,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    let Some(opts) = options else {
        return;
    };
    for opt in opts {
        let label = opt["label"].as_str().or_else(|| opt.as_str()).unwrap_or("");
        if label.to_lowercase().contains("suite:new") && question_lower.contains("suite:run") {
            let details = format!("Question: {question_text}, Option: {label}");
            emitter.emit(
                issues,
                IssueBlueprint::new(
                    IssueCode::WrongSkillCrossReference,
                    IssueCategory::SkillBehavior,
                    IssueSeverity::Medium,
                    "suite:run offering suite:new as structured choice",
                )
                .with_guidance(Guidance::fix_target_hint(
                    "skills/run/SKILL.md",
                    "suite:run should not offer suite:new as a structured option",
                )),
                &details,
            );
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

    let current_count = {
        let count = state.edit_counts.entry(path.to_string()).or_insert(0);
        *count += 1;
        *count
    };

    if current_count == 10 || current_count == 20 {
        let details = format!("Path: {path}");
        IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
            issues,
            IssueBlueprint::new(
                IssueCode::FileEditChurn,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Medium,
                format!("File modified {current_count} times - possible churn"),
            )
            .with_fingerprint(format!("{path}:{current_count}"))
            .with_guidance(Guidance::advisory(
                "Repeated modifications suggest trial-and-error",
            )),
            &details,
        );
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
                let details = format!("Path: {path}, name: {skill_name}");
                IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
                    issues,
                    IssueBlueprint::new(
                        IssueCode::ShortSkillNameInSkillFile,
                        IssueCategory::SkillBehavior,
                        IssueSeverity::Critical,
                        format!(
                            "SKILL.md name field uses short name '{skill_name}' instead of fully qualified"
                        ),
                    )
                    .with_fingerprint(format!("{path}:{skill_name}"))
                    .with_guidance(Guidance::fix_target_hint(
                        path.to_string(),
                        "Name should be fully qualified like 'suite:new' or 'suite:run'",
                    )),
                    &details,
                );
            }
        }
    }
}

/// Check for direct writes to harness-managed files via Write/Edit tools.
fn check_managed_file_writes(
    line_num: usize,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let path = input["file_path"].as_str().unwrap_or("");
    let path_lower = path.to_lowercase();
    for managed in patterns::MANAGED_CONTEXT_FILES {
        if path_lower.contains(managed) {
            let details = format!("Path: {path}");
            IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
                issues,
                IssueBlueprint::new(
                    IssueCode::DirectManagedFileWrite,
                    IssueCategory::UnexpectedBehavior,
                    IssueSeverity::Critical,
                    format!("Direct write to harness-managed file: {managed}"),
                )
                .with_fingerprint(path.to_string())
                .with_guidance(Guidance::fix_target_hint(
                    "skills/run/SKILL.md",
                    "Use harness commands to update managed files, not direct Write/Edit",
                )),
                &details,
            );
            break;
        }
    }
}
