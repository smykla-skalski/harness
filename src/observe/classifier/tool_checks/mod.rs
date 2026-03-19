mod lifecycle;
mod write_checks;

use std::path::Path;

use serde_json::Value;

use self::lifecycle::{
    check_uncommitted_source_code_edit, track_capture_between_groups, track_resource_lifecycle,
};
use self::write_checks::{
    check_managed_file_writes, check_manifest_created_during_run, check_write_edit_tool_use,
};
use super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use super::{OLD_SKILL_REGEX, RM_RECURSIVE_REGEX};
use crate::kernel::command_intent::ObservedCommand;
use crate::kernel::tooling::{ToolInput, legacy_tool_context};
use crate::observe::patterns;
use crate::observe::types::{
    Confidence, FixSafety, Issue, IssueCode, MessageRole, ScanState, SourceTool, ToolUseRecord,
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
    let tool = legacy_tool_context(name, input.clone(), None);

    // Uncommitted source code detection runs for Write/Edit and Bash to track
    // the edit-then-act-without-commit pattern across tool boundaries.
    if name == "Write" || name == "Edit" || name == "Bash" {
        check_uncommitted_source_code_edit(line_num, name, input, state, &mut issues);
    }

    if name == "Bash" {
        check_bash_tool_use(line_num, &tool.input, state, &mut issues);
    }

    if name == "AskUserQuestion" {
        check_ask_user_question(line_num, input, state, &mut issues);
    }

    if name == "Write" || name == "Edit" {
        check_write_edit_tool_use(line_num, name, input, state, &mut issues);
        check_managed_file_writes(line_num, input, state, &mut issues);
        check_manifest_created_during_run(line_num, input, state, &mut issues);
    }

    // Record tool_use for correlating with tool_result.
    if let Some(tool_id) = block["id"].as_str()
        && !tool_id.is_empty()
    {
        state
            .last_tool_uses
            .insert(tool_id.to_string(), ToolUseRecord { tool });
    }

    issues
}

// ─── tool_use sub-checks ───────────────────────────────────────────

/// Check Bash `tool_use` for specific patterns.
fn check_bash_tool_use(
    line_num: usize,
    input: &ToolInput,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let command = input.command_text().unwrap_or("");
    let details = format!("Command: {command}");
    let observed = ObservedCommand::parse(command);

    {
        let mut emitter = IssueEmitter::new(line_num, MessageRole::Assistant, state);

        if OLD_SKILL_REGEX.is_match(command) {
            emitter.emit(
                issues,
                IssueBlueprint::from_code(
                    IssueCode::OldSkillNameUsedInCommand,
                    "Old skill name used in harness command",
                )
                .with_guidance(Guidance::fix_hint(
                    "SKILL.md or model still references old skill names",
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AutoFixSafe)
                .with_source_tool(Some(SourceTool::Bash)),
                &details,
            );
        }

        check_harness_command_patterns(&observed, &details, &mut emitter, issues);
        check_destructive_patterns(command, &details, &mut emitter, issues);
        check_absolute_manifest_path(&observed, &details, &mut emitter, issues);
        check_direct_task_output_read(command, &details, &mut emitter, issues);
        check_env_var_construction(&observed, &details, &mut emitter, issues);
        check_sleep_prefix_before_harness(&observed, &details, &mut emitter, issues);
        check_truncated_verification_output(command, &details, &mut emitter, issues);
    }

    // Resource and capture tracking run outside the emitter scope so we can
    // mutably borrow state again for the tracking sets.
    track_resource_lifecycle(line_num, &observed, state, issues);
    track_capture_between_groups(line_num, &observed, state, issues);
    check_repeated_kubectl_queries(line_num, &observed, state, issues);
}

fn check_harness_command_patterns(
    command: &ObservedCommand,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if command.has_harness_subcommand("validator-decision") {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::InvalidHarnessSubcommandUsed,
                "Invalid harness subcommand/argument used",
            )
            .with_guidance(Guidance::fix_hint(
                "SKILL.md references a non-existent harness kind",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }

    if patterns::PYTHON_USAGE_SIGNALS
        .iter()
        .any(|signal| command.lower().contains(signal))
    {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::PythonUsedInBashToolUse,
                "Python used in Bash command - agents should never need python",
            )
            .with_guidance(Guidance::fix_hint(
                "Use harness commands or shell builtins instead of python one-liners",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

fn check_destructive_patterns(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if RM_RECURSIVE_REGEX.is_match(command) && !command.contains("&&") {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::UnverifiedRecursiveRemove,
                "Destructive rm -r without chained verification",
            )
            .with_guidance(Guidance::advisory(
                "Should verify target exists and is correct before deleting",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }

    if command.contains("make k3d/") || command.contains("make kind/") {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::RawClusterMakeTargetUsed,
                "Raw make target used for cluster operation",
            )
            .with_guidance(Guidance::fix_hint(
                "Use harness setup kuma cluster instead of raw make targets",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }

    if command.contains("git commit") || command.contains("git add") {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::UnauthorizedGitCommitDuringRun,
                "Git commit during active run",
            )
            .with_guidance(Guidance::fix_hint(
                "Commits during runs are tracked. Ensure code fixes are committed per contract rule 15.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

/// Detect `harness apply --manifest /absolute/path` usage.
///
/// Harness resolves manifest paths relative to the suite directory automatically.
/// Using absolute paths is unnecessary and fragile - relative paths like
/// `g13/01.yaml` are the expected convention.
fn check_absolute_manifest_path(
    command: &ObservedCommand,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if !command.has_harness_subcommand("apply") {
        return;
    }

    if command
        .manifest_paths()
        .iter()
        .any(|path| Path::new(path).is_absolute())
    {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::AbsoluteManifestPathUsed,
                "Absolute path used with harness apply",
            )
            .with_guidance(Guidance::fix_hint(
                "Use relative manifest paths (e.g. g13/01.yaml). \
                 Harness resolves them from the suite directory.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
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
            IssueBlueprint::from_code(
                IssueCode::DirectTaskOutputFileRead,
                "Direct read of internal task output file",
            )
            .with_guidance(Guidance::fix_hint(
                "Use TaskOutput tool instead of reading task files directly",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
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
    command: &ObservedCommand,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    // KUBECONFIG= is a specific, higher-signal pattern
    if command
        .words()
        .iter()
        .any(|word| word.starts_with("KUBECONFIG="))
    {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::ManualKubeconfigConstruction,
                "Agent manually setting KUBECONFIG",
            )
            .with_guidance(Guidance::fix_hint(
                "Agent manually setting KUBECONFIG. Harness injects it automatically.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
        return;
    }

    // Generic: `export FOO=bar` or `FOO=bar command` prefix patterns
    if command.starts_with_export() && command.raw().contains('=') {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::ManualExportConstruction,
                "Agent constructing env vars via export",
            )
            .with_guidance(Guidance::fix_hint(
                "Agent constructing env vars. Harness handles environment automatically.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
        return;
    }

    // `VAR=value command` prefix: first token looks like an env assignment
    // and there is at least one more token after it.
    if command.has_env_prefix_assignment() && command.words().len() > 1 {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::ManualEnvPrefixConstruction,
                "Agent constructing env var prefix",
            )
            .with_guidance(Guidance::fix_hint(
                "Agent constructing env vars. Harness handles environment automatically.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

/// Detect `sleep <N> && harness` or `sleep <N>; harness` command patterns.
///
/// Agents sometimes prefix harness commands with `sleep` to wait for resources
/// to settle. Harness has a built-in `--delay` flag for this purpose.
fn check_sleep_prefix_before_harness(
    command: &ObservedCommand,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if !command.starts_with_sleep() {
        return;
    }
    let has_harness_continuation = command.has_harness_after_chain()
        || command.raw().contains("&& harness")
        || command.raw().contains("; harness")
        || (command.raw().contains("&& /") && command.raw().contains("harness"));
    if has_harness_continuation {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::SleepPrefixBeforeHarnessCommand,
                "Sleep prefix before harness command",
            )
            .with_guidance(Guidance::fix_hint(
                "Use --delay flag instead of sleep prefix \
                 (e.g. harness apply --delay 8 --manifest ...)",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

/// Verification keywords that indicate a command whose output should not
/// be truncated. Matched case-insensitively against the command text.
const VERIFICATION_KEYWORDS: &[&str] =
    &["test", "check", "make", "verify", "lint", "clippy", "cargo"];

/// Detect verification commands piped through `tail` or `head`.
///
/// When an agent runs `make test | tail -10` or `cargo clippy | head -5`,
/// the truncated output can hide actual pass/fail markers. This is a
/// reliability risk because the agent may conclude "all tests pass" from
/// output where failures are not visible.
///
/// Only the portion of the command before the first `| tail` or `| head`
/// is checked for verification keywords, to avoid false positives from
/// flag values like `--label verify`.
fn check_truncated_verification_output(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    // Find the pipe-to-truncation point. Check both `| tail` and `| head`.
    let truncation_index = [command.find("| tail"), command.find("| head")]
        .iter()
        .filter_map(|position| *position)
        .min();

    let Some(pipe_position) = truncation_index else {
        return;
    };

    let before_pipe = command[..pipe_position].to_lowercase();
    let has_verification_keyword = VERIFICATION_KEYWORDS
        .iter()
        .any(|keyword| before_pipe.contains(keyword));

    if has_verification_keyword {
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::VerificationOutputTruncated,
                "Verification output truncated by tail/head",
            )
            .with_guidance(Guidance::advisory(
                "Never truncate verification output. Use full output or \
                 grep for specific pass/fail markers (e.g. grep FAIL).",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

/// Maximum line distance between kubectl queries to consider them part of
/// the same piecemeal sequence.
const KUBECTL_QUERY_WINDOW: usize = 20;

/// Number of repeated queries for the same resource that triggers a flag.
const KUBECTL_QUERY_THRESHOLD: usize = 3;

/// Detect piecemeal kubectl get/describe queries against the same resource.
///
/// When the agent runs `kubectl get crd meshretries.kuma.io` 4 times with
/// different jq filters instead of dumping the full output once, that is
/// wasteful and error-prone. This check tracks recent kubectl query targets
/// and flags when the same target appears 3+ times within a 20-line window.
fn check_repeated_kubectl_queries(
    line_num: usize,
    command: &ObservedCommand,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    // Skip harness-wrapped commands - those are already going through the
    // harness record/capture path and their output is being tracked.
    if command.is_harness_command() {
        return;
    }

    let Some(target) = command.kubectl_query_target() else {
        return;
    };

    // Evict entries outside the rolling window before counting.
    while state
        .kubectl_query_targets
        .front()
        .is_some_and(|(_, line)| line_num.saturating_sub(*line) > KUBECTL_QUERY_WINDOW)
    {
        state.kubectl_query_targets.pop_front();
    }

    state
        .kubectl_query_targets
        .push_back((target.clone(), line_num));

    let count = state
        .kubectl_query_targets
        .iter()
        .filter(|(existing_target, _)| *existing_target == target)
        .count();

    if count >= KUBECTL_QUERY_THRESHOLD {
        let details = format!("Resource: {target}, queries in window: {count}");
        IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::RepeatedKubectlQueryForSameResource,
                "Repeated kubectl queries for same resource - dump once and read the file",
            )
            .with_fingerprint(target)
            .with_guidance(Guidance::advisory(
                "Dump the full resource once with harness record, then read the file",
            ))
            .with_confidence(Confidence::Medium)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(Some(SourceTool::Bash)),
            &details,
        );
    }
}

/// Extract the normalized query target from a kubectl get/describe command.
///
/// Returns `Some("get <resource> [name]")` or `Some("describe <resource> [name]")`
/// for kubectl commands, stripping any jq filter, output format flags, and
/// namespace flags to normalize the target for comparison.
#[cfg(test)]
pub(super) fn extract_kubectl_query_target(command: &str) -> Option<String> {
    ObservedCommand::parse(command).kubectl_query_target()
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
            IssueBlueprint::from_code(
                IssueCode::ManifestFixPromptShown,
                "Manifest rejected by cluster - possible product bug",
            )
            .with_guidance(Guidance::fix_hint(
                "CRD or webhook rejected a manifest. Could be a suite error OR a product bug. \
                 Investigate whether the Go validator accepts what the CRD rejects.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::TriageRequired)
            .with_source_tool(Some(SourceTool::AskUserQuestion)),
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
            IssueBlueprint::from_code(
                IssueCode::ValidatorInstallPromptShown,
                "Validator install prompt when binary may already exist",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/new/SKILL.md",
                "Step 0 should check if binary exists first",
            ))
            .with_confidence(Confidence::Medium)
            .with_fix_safety(FixSafety::AutoFixGuarded)
            .with_source_tool(Some(SourceTool::AskUserQuestion)),
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
            IssueBlueprint::from_code(
                IssueCode::RuntimeDeviationPromptShown,
                "Runtime deviation - authored suite needs runtime correction",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/new/SKILL.md",
                "suite:new should produce suites that don't require runtime deviations",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::TriageRequired)
            .with_source_tool(Some(SourceTool::AskUserQuestion)),
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
                IssueBlueprint::from_code(
                    IssueCode::WrongSkillCrossReference,
                    "suite:run offering suite:new as structured choice",
                )
                .with_guidance(Guidance::fix_target_hint(
                    "skills/run/SKILL.md",
                    "suite:run should not offer suite:new as a structured option",
                ))
                .with_confidence(Confidence::Medium)
                .with_fix_safety(FixSafety::AdvisoryOnly)
                .with_source_tool(Some(SourceTool::AskUserQuestion)),
                &details,
            );
        }
    }
}
