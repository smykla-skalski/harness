use std::path::Path;

use crate::kernel::command_intent::ObservedCommand;
use crate::kernel::tooling::ToolInput;
use crate::observe::patterns;
use crate::observe::types::{
    Confidence, FixSafety, Issue, IssueCode, MessageRole, ScanState, SourceTool,
};

use super::super::RM_RECURSIVE_REGEX;
use super::super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use super::lifecycle::{track_capture_between_groups, track_resource_lifecycle};

/// Verification keywords that indicate a command whose output should not
/// be truncated. Matched case-insensitively against the command text.
const VERIFICATION_KEYWORDS: &[&str] =
    &["test", "check", "make", "verify", "lint", "clippy", "cargo"];

/// Maximum line distance between kubectl queries to consider them part of
/// the same piecemeal sequence.
const KUBECTL_QUERY_WINDOW: usize = 20;

/// Number of repeated queries for the same resource that triggers a flag.
const KUBECTL_QUERY_THRESHOLD: usize = 3;

/// Check Bash `tool_use` for specific patterns.
pub(super) fn check_bash_tool_use(
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

        check_harness_command_patterns(&observed, &details, &mut emitter, issues);
        check_destructive_patterns(command, &details, &mut emitter, issues);
        check_absolute_manifest_path(&observed, &details, &mut emitter, issues);
        check_direct_task_output_read(command, &details, &mut emitter, issues);
        check_env_var_construction(&observed, &details, &mut emitter, issues);
        check_sleep_prefix_before_harness(&observed, &details, &mut emitter, issues);
        check_truncated_verification_output(command, &details, &mut emitter, issues);
    }

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
                "Use relative manifest paths (e.g. g13/01.yaml). Harness resolves them from the suite directory.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

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

fn check_env_var_construction(
    command: &ObservedCommand,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
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
                "Use --delay flag instead of sleep prefix (e.g. harness apply --delay 8 --manifest ...)",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

fn check_truncated_verification_output(
    command: &str,
    details: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
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
                "Never truncate verification output. Use full output or grep for specific pass/fail markers (e.g. grep FAIL).",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(Some(SourceTool::Bash)),
            details,
        );
    }
}

fn check_repeated_kubectl_queries(
    line_num: usize,
    command: &ObservedCommand,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    if command.is_harness_command() {
        return;
    }

    let Some(target) = command.kubectl_query_target() else {
        return;
    };

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

#[cfg(test)]
pub(super) fn extract_kubectl_query_target(command: &str) -> Option<String> {
    ObservedCommand::parse(command).kubectl_query_target()
}
