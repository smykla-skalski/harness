use std::path::{Path, PathBuf};

use crate::kernel::skills::{SKILL_CREATE, SKILL_RUN};

use super::handoff::{CompactHandoff, CreateHandoff, RunnerHandoff};
use super::{CHAR_LIMIT, SECTION_CHAR_LIMIT, SECTION_LINE_LIMIT};

/// Render the hydration context for a compact handoff.
#[must_use]
pub fn render_hydration_context(handoff: &CompactHandoff<'_>, diverged_paths: &[&Path]) -> String {
    let mut lines = vec![
        "Kuma compaction handoff restored from saved harness state.".to_string(),
        "Continue immediately from the saved state below. Do not ask the user to restate context."
            .to_string(),
        format!("Project: {}", handoff.project_dir),
        format!("Saved at: {}", handoff.created_at),
    ];

    if handoff.runner.is_some() {
        lines.push(
            "Tracked cluster commands stay on \
             `harness run record --phase <phase> --label <label> --gid <group-id> -- kubectl <args>`."
                .to_string(),
        );
    }

    if !diverged_paths.is_empty() {
        let paths = diverged_paths
            .iter()
            .take(5)
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        lines.push(format!(
            "WARNING: the saved handoff diverged from live state; \
             reload only these files before continuing: {paths}"
        ));
    }

    // Render sections, prioritizing unfinished work
    let sections = ordered_sections(handoff);
    for section in &sections {
        match *section {
            "create" => {
                if let Some(ref auth) = handoff.create {
                    lines.extend(render_create_section(auth).lines().map(String::from));
                }
            }
            "runner" => {
                if let Some(ref runner) = handoff.runner {
                    lines.extend(render_runner_section(runner).lines().map(String::from));
                }
            }
            _ => {}
        }
    }

    truncate_lines(&lines, CHAR_LIMIT, SECTION_LINE_LIMIT * 2)
}

/// Render a runner restore context (for session-start without compact).
#[must_use]
pub fn render_runner_restore_context(project_dir: &Path, runner: &RunnerHandoff<'_>) -> String {
    let mut lines = vec![
        "Kuma harness active run restored from saved project state.".to_string(),
        format!("Project: {}", project_dir.to_string_lossy()),
    ];
    lines.extend(render_runner_section(runner).lines().map(String::from));
    lines.push(format!(
        "If the user passed `--resume {}`, treat this run as already initialized. \
         Read `{}` and continue from its next planned group instead of rerunning \
         `harness run start`.",
        runner.run_id,
        PathBuf::from(&*runner.run_dir)
            .join("run-status.json")
            .display()
    ));
    lines.push(
        "Do not run raw `kubectl` or `kubectl --kubeconfig ...` after restore. Use \
         `harness run record --phase <phase> --label <label> --gid <group-id> -- kubectl <args>`."
            .to_string(),
    );
    lines.push(
        "Do not blame the user for `guard-stop` feedback. If `preventedContinuation` is \
         false, treat it as advisory runtime metadata."
            .to_string(),
    );
    if runner.runner_phase.as_deref() == Some("aborted")
        && runner.verdict.as_deref() == Some("aborted")
        && !runner.remaining_groups.is_empty()
    {
        lines.push(
            "If this saved run was paused unexpectedly mid-run, do not edit control files \
             manually. Run `harness run resume` once, then continue \
             from the saved `next_planned_group`."
                .to_string(),
        );
    }
    lines.push(
        "Continue from the restored harness state. \
         Do not rerun `harness run start` unless the run directory is missing or corrupt."
            .to_string(),
    );

    truncate_lines(&lines, CHAR_LIMIT, SECTION_LINE_LIMIT * 2)
}

pub(super) fn render_runner_section(handoff: &RunnerHandoff<'_>) -> String {
    let mut lines = vec![
        format!("{SKILL_RUN}:"),
        format!("- Run: {}", handoff.run_id),
        format!("- Run dir: {}", handoff.run_dir),
        format!(
            "- Suite: {}",
            handoff.suite_path.as_deref().unwrap_or("unknown")
        ),
        format!(
            "- Profile: {}",
            handoff.profile.as_deref().unwrap_or("unknown")
        ),
        format!(
            "- Phase: {}",
            handoff.runner_phase.as_deref().unwrap_or("unknown")
        ),
        format!(
            "- Verdict: {}",
            handoff.verdict.as_deref().unwrap_or("unknown")
        ),
        format!(
            "- Executed groups: {}",
            if handoff.executed_groups.is_empty() {
                "none".to_string()
            } else {
                handoff.executed_groups.join(", ")
            }
        ),
        format!(
            "- Remaining groups: {}",
            if handoff.remaining_groups.is_empty() {
                "none".to_string()
            } else {
                handoff.remaining_groups.join(", ")
            }
        ),
        format!(
            "- Last state capture: {}",
            handoff.last_state_capture.as_deref().unwrap_or("missing")
        ),
        "- Cluster commands: \
         `harness run record --phase <phase> --label <label> --gid <group-id> -- kubectl <args>`; \
         never raw `kubectl`."
            .to_string(),
    ];

    // Aborted resume guidance
    if handoff.runner_phase.as_deref() == Some("aborted")
        && handoff.verdict.as_deref() == Some("aborted")
    {
        if handoff.remaining_groups.is_empty() {
            lines.push(
                "- Resume: the run is intentionally halted. Keep the aborted report as final."
                    .to_string(),
            );
        } else {
            lines.push("- Resume: Do not blame the user for `guard-stop` feedback.".to_string());
            lines.push("- Resume: run `harness run resume`.".to_string());
            lines.push(
                "- Resume: do not edit `run-status.json`, `run-report.md`, or reset verdict \
                 fields manually."
                    .to_string(),
            );
            lines.push("- Resume: continue from saved `next_planned_group`.".to_string());
        }
    }

    let state_preview: Vec<&str> = handoff
        .state_paths
        .iter()
        .take(4)
        .map(AsRef::as_ref)
        .collect();
    lines.push(format!("- Key state files: {}", state_preview.join(", ")));
    lines.push(format!("- Next action: {}", handoff.next_action));

    truncate_lines(&lines, SECTION_CHAR_LIMIT, SECTION_LINE_LIMIT)
}

fn render_create_section(handoff: &CreateHandoff<'_>) -> String {
    let lines = vec![
        format!("{SKILL_CREATE}:"),
        format!("- Suite dir: {}", handoff.suite_dir),
        format!(
            "- Suite name: {}",
            handoff.suite_name.as_deref().unwrap_or("unknown")
        ),
        format!(
            "- Feature: {}",
            handoff.feature.as_deref().unwrap_or("unknown")
        ),
        format!(
            "- Phase: {}",
            handoff.create_phase.as_deref().unwrap_or("missing")
        ),
        format!(
            "- Saved payloads: {}",
            if handoff.saved_payloads.is_empty() {
                "none".to_string()
            } else {
                handoff.saved_payloads.join(", ")
            }
        ),
        format!("- Written files: {}", handoff.suite_files.len()),
        format!(
            "- Key state files: {}",
            handoff
                .state_paths
                .iter()
                .take(5)
                .map(AsRef::as_ref)
                .collect::<Vec<&str>>()
                .join(", ")
        ),
        format!("- Next action: {}", handoff.next_action),
    ];

    truncate_lines(&lines, SECTION_CHAR_LIMIT, SECTION_LINE_LIMIT)
}

pub(super) fn ordered_sections<'a>(handoff: &'a CompactHandoff<'_>) -> Vec<&'a str> {
    let mut sections: Vec<(&str, bool)> = Vec::new();
    if let Some(ref a) = handoff.create {
        let unfinished = !matches!(a.create_phase.as_deref(), Some("complete" | "cancelled"));
        sections.push(("create", unfinished));
    }
    if let Some(ref r) = handoff.runner {
        let unfinished = r.verdict.as_deref().is_none()
            || r.verdict.as_deref() == Some("pending")
            || r.completed_at.is_none();
        sections.push(("runner", unfinished));
    }

    // Unfinished sections first
    sections.sort_by_key(|(name, unfinished)| (!unfinished, *name));
    sections.into_iter().map(|(name, _)| name).collect()
}

pub(super) fn truncate_lines(lines: &[String], char_limit: usize, line_limit: usize) -> String {
    let mut result = String::new();
    let mut total = 0;
    for line in lines.iter().take(line_limit) {
        let remaining = char_limit.saturating_sub(total);
        if remaining == 0 {
            break;
        }
        let truncated = if line.len() > remaining {
            &line[..line.floor_char_boundary(remaining)]
        } else {
            line.as_str()
        };
        if truncated.is_empty() {
            break;
        }
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(truncated);
        total += truncated.len() + 1;
        if total >= char_limit {
            break;
        }
    }
    result
}
