use std::path::Path;

use serde_json::Value;

use super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use super::{OLD_SKILL_REGEX, RM_RECURSIVE_REGEX, SKILL_NAME_REGEX};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole, ScanState,
    SourceTool, ToolUseRecord,
};
use crate::shell_parse::is_env_assignment;

/// Check a `tool_use` block for issues.
pub fn check_tool_use_for_issues(
    line_num: usize,
    block: &Value,
    state: &mut ScanState,
) -> Vec<Issue> {
    let mut issues = Vec::new();
    let name = block["name"].as_str().unwrap_or("");
    let input = &block["input"];

    // Uncommitted source code detection runs for Write/Edit and Bash to track
    // the edit-then-act-without-commit pattern across tool boundaries.
    if name == "Write" || name == "Edit" || name == "Bash" {
        check_uncommitted_source_code_edit(line_num, name, input, state, &mut issues);
    }

    if name == "Bash" {
        check_bash_tool_use(line_num, input, state, &mut issues);
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
        state.tool_use_serial += 1;
        state.last_tool_uses.insert(
            tool_id.to_string(),
            ToolUseRecord {
                name: name.to_string(),
                input: input.clone(),
            },
        );

        // Prune old entries to cap memory usage
        if state.last_tool_uses.len() > 100 {
            let cutoff = state.last_tool_uses.len() - 100;
            let keys_to_remove: Vec<String> =
                state.last_tool_uses.keys().take(cutoff).cloned().collect();
            for key in keys_to_remove {
                state.last_tool_uses.remove(&key);
            }
        }
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

    {
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
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AutoFixSafe)
                .with_source_tool(Some(SourceTool::Bash)),
                &details,
            );
        }

        check_harness_command_patterns(command, &details, &mut emitter, issues);
        check_destructive_patterns(command, &details, &mut emitter, issues);
        check_absolute_manifest_path(command, &details, &mut emitter, issues);
        check_direct_task_output_read(command, &details, &mut emitter, issues);
        check_env_var_construction(command, &details, &mut emitter, issues);
        check_sleep_prefix_before_harness(command, &details, &mut emitter, issues);
        check_truncated_verification_output(command, &details, &mut emitter, issues);
    }

    // Resource and capture tracking run outside the emitter scope so we can
    // mutably borrow state again for the tracking sets.
    track_resource_lifecycle(line_num, command, state, issues);
    track_capture_between_groups(line_num, command, state, issues);
    check_repeated_kubectl_queries(line_num, command, state, issues);
}

/// Track resource create/delete lifecycle across a test group.
///
/// When `harness apply` is called, we extract the manifest filename stem
/// and add it to `pending_resource_creates`. When `harness delete` is called,
/// we remove matching entries. When `harness report group` is called, any
/// remaining entries are flagged as uncleaned resources, and the set is
/// cleared for the next group.
fn track_resource_lifecycle(
    line_num: usize,
    command: &str,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    if !command.contains("harness") {
        return;
    }

    // Track creates from `harness apply --manifest <path>`
    if command.contains("apply") && command.contains("--manifest") {
        for manifest_name in extract_manifest_stems(command) {
            state.pending_resource_creates.insert(manifest_name);
        }
        return;
    }

    // Track deletes from `harness delete --manifest <path>`
    if command.contains("delete") && command.contains("--manifest") {
        for manifest_name in extract_manifest_stems(command) {
            state.pending_resource_creates.remove(&manifest_name);
        }
        return;
    }

    // On `harness report group`, check for leftover creates
    if command.contains("report") && command.contains("group") {
        if state.pending_resource_creates.is_empty() {
            return;
        }

        let mut leftover: Vec<&str> = state
            .pending_resource_creates
            .iter()
            .map(String::as_str)
            .collect();
        leftover.sort_unstable();
        let resource_list = leftover.join(", ");
        let details = format!("Uncleaned resources: {resource_list}");

        IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
            issues,
            IssueBlueprint::new(
                IssueCode::ResourceNotCleanedUpBeforeGroupEnd,
                IssueCategory::SkillBehavior,
                IssueSeverity::Low,
                "Resources created but not cleaned up before group end",
            )
            .with_fingerprint(resource_list)
            .with_guidance(Guidance::advisory(
                "Delete test resources after verification to avoid contaminating later groups",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(Some(SourceTool::Bash)),
            &details,
        );

        state.pending_resource_creates.clear();
    }
}

/// Track state capture calls between test group reports.
///
/// When `harness capture` is seen, `seen_capture_since_last_group_report` is
/// set to `true`. When `harness report group` is seen, we check whether a
/// capture happened since the previous group report. The `--capture-label` flag
/// on report group triggers an inline capture, so its presence suppresses the
/// warning.
fn track_capture_between_groups(
    line_num: usize,
    command: &str,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    if !command.contains("harness") {
        return;
    }

    // `harness capture` sets the flag
    if command.contains("capture") && !command.contains("report") {
        state.seen_capture_since_last_group_report = true;
        return;
    }

    // `harness report group` checks the flag
    if command.contains("report") && command.contains("group") {
        let has_capture_label = command.contains("--capture-label");

        // Only warn when this is not the first group, no standalone capture
        // was seen, and the command does not include --capture-label.
        if state.seen_any_group_report
            && !state.seen_capture_since_last_group_report
            && !has_capture_label
        {
            let details = format!("Command: {command}");
            IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
                issues,
                IssueBlueprint::new(
                    IssueCode::GroupReportedWithoutCapture,
                    IssueCategory::SkillBehavior,
                    IssueSeverity::Medium,
                    "Group reported without a preceding state capture",
                )
                .with_fingerprint("group_reported_without_capture")
                .with_guidance(Guidance::advisory(
                    "Run 'harness capture' between groups or pass --capture-label \
                     to preserve state snapshots before and after each group",
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AdvisoryOnly)
                .with_source_tool(Some(SourceTool::Bash)),
                &details,
            );
        }

        // Reset for the next inter-group window
        state.seen_capture_since_last_group_report = false;
        state.seen_any_group_report = true;
    }
}

/// Extract manifest filename stems from a command string.
///
/// Given `harness apply --manifest g13/01-meshtrace.yaml --manifest g13/02-patch.yaml`,
/// returns `["01-meshtrace", "02-patch"]`.
fn extract_manifest_stems(command: &str) -> Vec<String> {
    let mut stems = Vec::new();
    let mut tokens = command.split_whitespace();
    while let Some(token) = tokens.next() {
        if token == "--manifest"
            && let Some(path) = tokens.next()
            && let Some(stem) = Path::new(path).file_stem().and_then(|s| s.to_str())
        {
            stems.push(stem.to_string());
        }
    }
    stems
}

fn check_harness_command_patterns(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
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
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
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
            IssueBlueprint::new(
                IssueCode::UnverifiedRecursiveRemove,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Medium,
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
            IssueBlueprint::new(
                IssueCode::RawClusterMakeTargetUsed,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Critical,
                "Raw make target used for cluster operation",
            )
            .with_guidance(Guidance::fix_hint(
                "Use harness cluster instead of raw make targets",
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
            IssueBlueprint::new(
                IssueCode::UnauthorizedGitCommitDuringRun,
                IssueCategory::SkillBehavior,
                IssueSeverity::Low,
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
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AutoFixSafe)
                .with_source_tool(Some(SourceTool::Bash)),
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
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
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
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AutoFixSafe)
                .with_source_tool(Some(SourceTool::Bash)),
                details,
            );
        }
    }
}

/// Detect `sleep <N> && harness` or `sleep <N>; harness` command patterns.
///
/// Agents sometimes prefix harness commands with `sleep` to wait for resources
/// to settle. Harness has a built-in `--delay` flag for this purpose.
fn check_sleep_prefix_before_harness(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    let trimmed = command.trim_start();
    if !trimmed.starts_with("sleep ") {
        return;
    }
    let has_harness_continuation = trimmed.contains("&& harness")
        || trimmed.contains("; harness")
        || trimmed.contains("&& /") && trimmed.contains("harness");
    if has_harness_continuation {
        emitter.emit(
            issues,
            IssueBlueprint::new(
                IssueCode::SleepPrefixBeforeHarnessCommand,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Low,
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
            IssueBlueprint::new(
                IssueCode::VerificationOutputTruncated,
                IssueCategory::SkillBehavior,
                IssueSeverity::Low,
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
    command: &str,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    // Skip harness-wrapped commands - those are already going through the
    // harness record/capture path and their output is being tracked.
    let trimmed = command.trim_start();
    if trimmed.starts_with("harness ") {
        return;
    }

    let Some(target) = extract_kubectl_query_target(command) else {
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
            IssueBlueprint::new(
                IssueCode::RepeatedKubectlQueryForSameResource,
                IssueCategory::UnexpectedBehavior,
                IssueSeverity::Low,
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
pub(super) fn extract_kubectl_query_target(command: &str) -> Option<String> {
    // Find `kubectl` followed by `get` or `describe` anywhere in the command.
    // Commands may be piped (kubectl ... | jq ...) or chained.
    let kubectl_part = command
        .split('|')
        .next()
        .unwrap_or(command)
        .split("&&")
        .find(|segment| segment.contains("kubectl"))?;

    let tokens: Vec<&str> = kubectl_part.split_whitespace().collect();
    let kubectl_position = tokens.iter().position(|token| *token == "kubectl")?;
    let remaining = &tokens[kubectl_position + 1..];

    // Find the verb (get or describe)
    let (verb_index, verb) = remaining.iter().enumerate().find_map(|(index, token)| {
        if *token == "get" || *token == "describe" {
            Some((index, *token))
        } else {
            None
        }
    })?;

    let after_verb = &remaining[verb_index + 1..];

    // Collect positional arguments (resource type and optional name),
    // skipping flags and their values.
    let mut positional = Vec::new();
    let mut skip_next = false;
    for token in after_verb {
        if skip_next {
            skip_next = false;
            continue;
        }
        if token.starts_with('-') {
            // Flags that take a value argument
            if *token == "-o"
                || *token == "-n"
                || *token == "--namespace"
                || *token == "--output"
                || *token == "-l"
                || *token == "--selector"
                || *token == "--field-selector"
            {
                skip_next = true;
            }
            continue;
        }
        positional.push(*token);
        if positional.len() >= 2 {
            break;
        }
    }

    if positional.is_empty() {
        return None;
    }

    Some(format!("{verb} {}", positional.join(" ")))
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
            IssueBlueprint::new(
                IssueCode::ValidatorInstallPromptShown,
                IssueCategory::SkillBehavior,
                IssueSeverity::Medium,
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
            IssueBlueprint::new(
                IssueCode::RuntimeDeviationPromptShown,
                IssueCategory::SkillBehavior,
                IssueSeverity::Critical,
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
                IssueBlueprint::new(
                    IssueCode::WrongSkillCrossReference,
                    IssueCategory::SkillBehavior,
                    IssueSeverity::Medium,
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

/// Check Write/Edit `tool_use` for churn and naming issues.
fn check_write_edit_tool_use(
    line_num: usize,
    tool_name: &str,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let path = input["file_path"].as_str().unwrap_or("");
    let source_tool = if tool_name == "Write" {
        Some(SourceTool::Write)
    } else {
        Some(SourceTool::Edit)
    };

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
            ))
            .with_confidence(Confidence::Medium)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(source_tool),
            &details,
        );
    }

    // Inverted skill name rule: flag colon-prefixed names in SKILL.md files.
    // The actual convention in checked-in skills IS short names (e.g. "new", "run").
    // The colon-prefixed form (e.g. "suite:new") is for CLI invocations only.
    if path.contains("SKILL.md") {
        let content = if tool_name == "Write" {
            input["content"].as_str().unwrap_or("")
        } else {
            input["new_string"].as_str().unwrap_or("")
        };
        if let Some(captures) = SKILL_NAME_REGEX.captures(content) {
            let skill_name = captures.get(1).map_or("", |m| m.as_str());
            if skill_name.contains(':') {
                let details = format!("Path: {path}, name: {skill_name}");
                IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
                    issues,
                    IssueBlueprint::new(
                        IssueCode::ShortSkillNameInSkillFile,
                        IssueCategory::SkillBehavior,
                        IssueSeverity::Critical,
                        format!(
                            "SKILL.md name field uses colon-prefixed '{skill_name}' - should be short name"
                        ),
                    )
                    .with_fingerprint(format!("{path}:{skill_name}"))
                    .with_guidance(Guidance::fix_target_hint(
                        path.to_string(),
                        "Name should be the short form like 'new' or 'run', not 'suite:new'",
                    ))
                    .with_confidence(Confidence::High)
                    .with_fix_safety(FixSafety::AutoFixSafe)
                    .with_source_tool(source_tool),
                    &details,
                );
            }
        }
    }
}

/// Detect when Write/Edit creates a YAML file inside a `manifests/` directory.
///
/// During suite:run, all manifests must already exist in the suite. Creating
/// new manifests on the fly is a suite:new authoring defect.
fn check_manifest_created_during_run(
    line_num: usize,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let path = input["file_path"].as_str().unwrap_or("");
    if !path.contains("/manifests/") {
        return;
    }
    let extension = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    if !extension.eq_ignore_ascii_case("yaml") && !extension.eq_ignore_ascii_case("yml") {
        return;
    }
    let details = format!("Path: {path}");
    IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
        issues,
        IssueBlueprint::new(
            IssueCode::ManifestCreatedDuringRun,
            IssueCategory::SkillBehavior,
            IssueSeverity::Critical,
            "Manifest created during run - should be authored in suite:new",
        )
        .with_fingerprint(path.to_string())
        .with_guidance(Guidance::fix_target_hint(
            "skills/new/SKILL.md",
            "All manifests must exist before the run starts. \
             A missing manifest means suite:new failed to author it.",
        ))
        .with_confidence(Confidence::High)
        .with_fix_safety(FixSafety::TriageRequired)
        .with_source_tool(Some(SourceTool::Write)),
        &details,
    );
}

/// Source code file extensions that require a commit before continuing.
const SOURCE_CODE_EXTENSIONS: &[&str] = &[
    "go", "rs", "py", "js", "ts", "java", "c", "cpp", "h", "hpp", "rb", "sh",
];

/// Returns true if the path looks like a source code file based on extension.
fn is_source_code_file(path: &str) -> bool {
    let extension = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    SOURCE_CODE_EXTENSIONS
        .iter()
        .any(|ext| extension.eq_ignore_ascii_case(ext))
}

/// Detect source code edits without an intervening git commit.
///
/// Contract rule 15 says "commit code fixes before continuing." When Write/Edit
/// targets a source code file, track it. If the next Write/Edit or harness
/// command arrives without a `git commit` in between, emit an issue.
fn check_uncommitted_source_code_edit(
    line_num: usize,
    tool_name: &str,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    if tool_name == "Write" || tool_name == "Edit" {
        let path = input["file_path"].as_str().unwrap_or("");
        if is_source_code_file(path) {
            if state.source_code_edited_without_commit {
                // Second source code edit (or harness action) without commit
                let details = format!("Path: {path}");
                IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
                    issues,
                    IssueBlueprint::new(
                        IssueCode::UncommittedSourceCodeEdit,
                        IssueCategory::SkillBehavior,
                        IssueSeverity::Medium,
                        "Source code edited without committing previous changes",
                    )
                    .with_fingerprint("uncommitted_source_code_edit")
                    .with_guidance(Guidance::fix_target_hint(
                        "skills/run/SKILL.md",
                        "Commit code fixes before re-deploying or re-testing. \
                         Use git add <files> && git commit -m 'fix: description'.",
                    ))
                    .with_confidence(Confidence::High)
                    .with_fix_safety(FixSafety::TriageRequired)
                    .with_source_tool(Some(if tool_name == "Write" {
                        SourceTool::Write
                    } else {
                        SourceTool::Edit
                    })),
                    &details,
                );
            }
            // Mark that source code was edited (whether or not we emitted)
            state.source_code_edited_without_commit = true;
        }
    } else if tool_name == "Bash" {
        let command = input["command"].as_str().unwrap_or("");
        if command.contains("git commit") {
            state.source_code_edited_without_commit = false;
        } else if state.source_code_edited_without_commit && command.contains("harness") {
            let details = format!("Command: {command}");
            IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
                issues,
                IssueBlueprint::new(
                    IssueCode::UncommittedSourceCodeEdit,
                    IssueCategory::SkillBehavior,
                    IssueSeverity::Medium,
                    "Harness command run with uncommitted source code changes",
                )
                .with_fingerprint("uncommitted_source_before_harness")
                .with_guidance(Guidance::fix_target_hint(
                    "skills/run/SKILL.md",
                    "Commit code fixes before re-deploying or re-testing. \
                     Use git add <files> && git commit -m 'fix: description'.",
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::TriageRequired)
                .with_source_tool(Some(SourceTool::Bash)),
                &details,
            );
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
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AutoFixSafe)
                .with_source_tool(Some(SourceTool::Write)),
                &details,
            );
            break;
        }
    }
}
