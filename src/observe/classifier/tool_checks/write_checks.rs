use std::path::Path;

use serde_json::Value;

use crate::observe::classifier::SKILL_NAME_REGEX;
use crate::observe::classifier::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use crate::observe::patterns;
use crate::observe::types::{
    Confidence, FixSafety, Issue, IssueCode, MessageRole, ScanState, SourceTool,
};

/// Source code file extensions that require a commit before continuing.
pub(super) const SOURCE_CODE_EXTENSIONS: &[&str] = &[
    "go", "rs", "py", "js", "ts", "java", "c", "cpp", "h", "hpp", "rb", "sh",
];

/// Returns true if the path looks like a source code file based on extension.
pub(super) fn is_source_code_file(path: &str) -> bool {
    let extension = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    SOURCE_CODE_EXTENSIONS
        .iter()
        .any(|ext| extension.eq_ignore_ascii_case(ext))
}

/// Check Write/Edit `tool_use` for churn and naming issues.
pub(super) fn check_write_edit_tool_use(
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
    track_cross_agent_editor(state, path);

    if current_count == 10 || current_count == 20 {
        let details = format!("Path: {path}");
        IssueEmitter::new(line_num, MessageRole::Assistant, state).emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::FileEditChurn,
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
    // The colon-prefixed form (e.g. "suite:create") is for CLI invocations only.
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
                    IssueBlueprint::from_code(
                        IssueCode::ShortSkillNameInSkillFile,
                        format!(
                            "SKILL.md name field uses colon-prefixed '{skill_name}' - should be short name"
                        ),
                    )
                    .with_fingerprint(format!("{path}:{skill_name}"))
                    .with_guidance(Guidance::fix_target_hint(
                        path.to_string(),
                        "Name should be the short form like 'new' or 'run', not 'suite:create'",
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
/// new manifests on the fly is a suite:create defect.
pub(super) fn check_manifest_created_during_run(
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
        IssueBlueprint::from_code(
            IssueCode::ManifestCreatedDuringRun,
            "Manifest created during run - should be authored in suite:create",
        )
        .with_fingerprint(path.to_string())
        .with_guidance(Guidance::fix_target_hint(
            "skills/create/SKILL.md",
            "All manifests must exist before the run starts. \
             A missing manifest means suite:create failed to create it.",
        ))
        .with_confidence(Confidence::High)
        .with_fix_safety(FixSafety::TriageRequired)
        .with_source_tool(Some(SourceTool::Write)),
        &details,
    );
}

/// Check for direct writes to harness-managed files via Write/Edit tools.
pub(super) fn check_managed_file_writes(
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
                IssueBlueprint::from_code(
                    IssueCode::DirectManagedFileWrite,
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

fn track_cross_agent_editor(state: &mut ScanState, path: &str) {
    if state.orchestration_session_id.is_none() {
        return;
    }
    let Some(agent_id) = state.agent_id.clone() else {
        return;
    };
    state
        .cross_agent_editors
        .entry(path.to_string())
        .or_default()
        .insert(agent_id);
}
