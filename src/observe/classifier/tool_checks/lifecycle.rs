use std::path::Path;

use serde_json::Value;

use super::command::ObservedCommand;
use crate::observe::classifier::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use crate::observe::types::{
    Confidence, FixSafety, Issue, IssueCode, MessageRole, ScanState, SourceTool,
};

/// Track resource create/delete lifecycle across a test group.
///
/// When `harness apply` is called, we extract the manifest filename stem
/// and add it to `pending_resource_creates`. When `harness delete` is called,
/// we remove matching entries. When `harness report group` is called, any
/// remaining entries are flagged as uncleaned resources, and the set is
/// cleared for the next group.
pub(super) fn track_resource_lifecycle(
    line_num: usize,
    command: &ObservedCommand<'_>,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    if !command.is_harness_command() {
        return;
    }

    // Track creates from `harness apply --manifest <path>`
    if command.has_harness_subcommand("apply") {
        for manifest_name in extract_manifest_stems(command) {
            state.pending_resource_creates.insert(manifest_name);
        }
        return;
    }

    // Track deletes from `harness delete --manifest <path>`
    if command.has_harness_subcommand("delete") {
        for manifest_name in extract_manifest_stems(command) {
            state.pending_resource_creates.remove(&manifest_name);
        }
        return;
    }

    // On `harness report group`, check for leftover creates
    if command.has_harness_subcommand("report")
        && command.harness_spans().any(|span| {
            span.first().is_some_and(|word| *word == "report")
                && span.get(1).is_some_and(|word| *word == "group")
        })
    {
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
            IssueBlueprint::from_code(
                IssueCode::ResourceNotCleanedUpBeforeGroupEnd,
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
pub(super) fn track_capture_between_groups(
    line_num: usize,
    command: &ObservedCommand<'_>,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    if !command.is_harness_command() {
        return;
    }

    // `harness capture` sets the flag
    if command.has_harness_subcommand("capture") && !command.has_harness_subcommand("report") {
        state.seen_capture_since_last_group_report = true;
        return;
    }

    // `harness report group` checks the flag
    if command.has_harness_subcommand("report")
        && command.harness_spans().any(|span| {
            span.first().is_some_and(|word| *word == "report")
                && span.get(1).is_some_and(|word| *word == "group")
        })
    {
        let has_capture_label = command.harness_has_flag("--capture-label");

        // Only warn when this is not the first group, no standalone capture
        // was seen, and the command does not include --capture-label.
        if state.seen_any_group_report
            && !state.seen_capture_since_last_group_report
            && !has_capture_label
        {
            let details = format!("Command: {}", command.raw());
            IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
                issues,
                IssueBlueprint::from_code(
                    IssueCode::GroupReportedWithoutCapture,
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
fn extract_manifest_stems(command: &ObservedCommand<'_>) -> Vec<String> {
    command
        .manifest_paths()
        .into_iter()
        .filter_map(|path| {
            Path::new(path)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .map(ToString::to_string)
        })
        .collect()
}

/// Detect source code edits without an intervening git commit.
///
/// Contract rule 15 says "commit code fixes before continuing." When Write/Edit
/// targets a source code file, track it. If the next Write/Edit or harness
/// command arrives without a `git commit` in between, emit an issue.
pub(super) fn check_uncommitted_source_code_edit(
    line_num: usize,
    tool_name: &str,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    match tool_name {
        "Write" | "Edit" => {
            track_source_code_write(line_num, tool_name, input, state, issues);
        }
        "Bash" => {
            track_bash_commit_state(line_num, input, state, issues);
        }
        _ => {}
    }
}

/// Track Write/Edit operations on source code files and emit when a prior edit
/// was not committed.
fn track_source_code_write(
    line_num: usize,
    tool_name: &str,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let path = input["file_path"].as_str().unwrap_or("");
    if !super::write_checks::is_source_code_file(path) {
        return;
    }

    if state.source_code_edited_without_commit {
        let source_tool = if tool_name == "Write" {
            SourceTool::Write
        } else {
            SourceTool::Edit
        };
        let details = format!("Path: {path}");
        IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::UncommittedSourceCodeEdit,
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
            .with_source_tool(Some(source_tool)),
            &details,
        );
    }

    state.source_code_edited_without_commit = true;
}

/// Check Bash commands for git commits (which clear the dirty flag) or harness
/// invocations that should have been preceded by a commit.
fn track_bash_commit_state(
    line_num: usize,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let command = input["command"].as_str().unwrap_or("");
    if command.contains("git commit") {
        state.source_code_edited_without_commit = false;
        return;
    }

    if !state.source_code_edited_without_commit || !command.contains("harness") {
        return;
    }

    let details = format!("Command: {command}");
    IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
        issues,
        IssueBlueprint::from_code(
            IssueCode::UncommittedSourceCodeEdit,
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
