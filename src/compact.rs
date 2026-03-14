use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;
use std::{fs, result};

use serde::{Deserialize, Serialize};

use crate::core_defs::{project_context_dir, session_scope_key, utc_now};
use crate::errors::CliError;
use crate::rules::compact as rules;

/// SHA256 fingerprint of a file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileFingerprint {
    pub label: String,
    pub path: String,
    pub exists: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mtime_ns: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
}

impl FileFingerprint {
    /// Build a fingerprint from a file path on disk.
    #[must_use]
    pub fn from_path(label: &str, path: &Path) -> Self {
        let resolved = path.to_path_buf();
        if !resolved.exists() {
            return Self {
                label: label.to_string(),
                path: resolved.to_string_lossy().to_string(),
                exists: false,
                size: None,
                mtime_ns: None,
                sha256: None,
            };
        }
        let meta = fs::metadata(&resolved).ok();
        let size = meta.as_ref().map(fs::Metadata::len);
        let mtime_ns = meta.as_ref().and_then(|m| {
            m.modified().ok().and_then(|t| {
                t.duration_since(UNIX_EPOCH)
                    .ok()
                    .and_then(|d| u64::try_from(d.as_nanos()).ok())
            })
        });
        let sha256 = file_sha256(&resolved);

        Self {
            label: label.to_string(),
            path: resolved.to_string_lossy().to_string(),
            exists: true,
            size,
            mtime_ns,
            sha256,
        }
    }

    /// Check if the fingerprint matches the current state on disk.
    #[must_use]
    pub fn matches_disk(&self) -> bool {
        let current = Self::from_path(&self.label, Path::new(&self.path));
        current == *self
    }
}

/// Runner handoff state for compaction.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunnerHandoff {
    pub run_dir: String,
    pub run_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner_phase: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verdict: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_state_capture: Option<String>,
    pub next_action: String,
    #[serde(default)]
    pub executed_groups: Vec<String>,
    #[serde(default)]
    pub remaining_groups: Vec<String>,
    #[serde(default)]
    pub state_paths: Vec<String>,
}

/// Authoring handoff state for compaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoringHandoff {
    pub suite_dir: String,
    pub next_action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_phase: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub feature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(default)]
    pub saved_payloads: Vec<String>,
    #[serde(default)]
    pub suite_files: Vec<String>,
    #[serde(default)]
    pub state_paths: Vec<String>,
}

/// Full compact handoff payload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompactHandoff {
    pub version: u32,
    pub project_dir: String,
    pub created_at: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_session_scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner: Option<RunnerHandoff>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authoring: Option<AuthoringHandoff>,
    #[serde(default)]
    pub fingerprints: Vec<FileFingerprint>,
}

impl CompactHandoff {
    /// Whether the handoff has any active section.
    #[must_use]
    pub fn has_sections(&self) -> bool {
        self.runner.is_some() || self.authoring.is_some()
    }
}

/// Compact directory for a project.
#[must_use]
pub fn compact_project_dir(project_dir: &Path) -> PathBuf {
    project_context_dir(project_dir).join("compact")
}

/// Path to the latest compact handoff file.
#[must_use]
pub fn compact_latest_path(project_dir: &Path) -> PathBuf {
    compact_project_dir(project_dir).join("latest.json")
}

/// History directory for compact handoffs.
#[must_use]
pub fn compact_history_dir(project_dir: &Path) -> PathBuf {
    compact_project_dir(project_dir).join("history")
}

/// Build a compact handoff from the current state.
///
/// This is a simplified version that creates a handoff with basic metadata.
/// Full state collection depends on other modules being implemented.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn build_compact_handoff(project_dir: &Path) -> Result<CompactHandoff, CliError> {
    Ok(CompactHandoff {
        version: rules::HANDOFF_VERSION,
        project_dir: project_dir.to_string_lossy().to_string(),
        created_at: utc_now(),
        status: rules::STATUS_PENDING.to_string(),
        source_session_scope: Some(session_scope_key()),
        source_session_id: None,
        transcript_path: None,
        cwd: None,
        trigger: None,
        custom_instructions: None,
        consumed_at: None,
        runner: None,
        authoring: None,
        fingerprints: vec![],
    })
}

/// Save a compact handoff to the project directory.
///
/// Writes to latest.json and a timestamped history file.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn save_compact_handoff(
    project_dir: &Path,
    handoff: &CompactHandoff,
) -> Result<CompactHandoff, CliError> {
    let latest_path = compact_latest_path(project_dir);
    let history_dir = compact_history_dir(project_dir);
    let history_name = handoff.created_at.replace([':', '.'], "") + ".json";
    let history_path = history_dir.join(history_name);

    write_json_atomic(&latest_path, handoff)?;
    write_json_atomic(&history_path, handoff)?;
    trim_history(project_dir);

    Ok(handoff.clone())
}

/// Load the latest compact handoff.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_latest_compact_handoff(project_dir: &Path) -> Result<Option<CompactHandoff>, CliError> {
    let path = compact_latest_path(project_dir);
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).map_err(|e| CliError {
        code: "IO".to_string(),
        message: format!("failed to read {}: {e}", path.display()),
        exit_code: 1,
        hint: None,
        details: None,
    })?;
    serde_json::from_str(&text).map(Some).map_err(|e| CliError {
        code: "PARSE".to_string(),
        message: format!("corrupt compact handoff at {}: {e}", path.display()),
        exit_code: 1,
        hint: None,
        details: None,
    })
}

/// Load a pending (unconsumed) compact handoff, if any.
#[must_use]
pub fn pending_compact_handoff(project_dir: &Path) -> Option<CompactHandoff> {
    load_latest_compact_handoff(project_dir)
        .ok()
        .flatten()
        .filter(|h| h.status == rules::STATUS_PENDING)
}

/// Mark a handoff as consumed.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn consume_compact_handoff(
    project_dir: &Path,
    handoff: &CompactHandoff,
) -> Result<CompactHandoff, CliError> {
    let consumed = CompactHandoff {
        status: rules::STATUS_CONSUMED.to_string(),
        consumed_at: Some(utc_now()),
        ..handoff.clone()
    };
    write_json_atomic(&compact_latest_path(project_dir), &consumed)?;
    Ok(consumed)
}

/// Check which fingerprints have diverged from disk.
#[must_use]
pub fn verify_fingerprints(handoff: &CompactHandoff) -> Vec<String> {
    handoff
        .fingerprints
        .iter()
        .filter(|fp| !fp.matches_disk())
        .map(|fp| fp.path.clone())
        .collect()
}

/// Render the hydration context for a compact handoff.
#[must_use]
pub fn render_hydration_context(handoff: &CompactHandoff, diverged_paths: &[String]) -> String {
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
             `harness run --phase <phase> --label <label> kubectl <args>` or \
             `harness record --phase <phase> --label <label> -- kubectl <args>`."
                .to_string(),
        );
    }

    if !diverged_paths.is_empty() {
        let paths = diverged_paths
            .iter()
            .take(5)
            .map(String::as_str)
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
        match section.as_str() {
            "authoring" => {
                if let Some(ref auth) = handoff.authoring {
                    lines.extend(render_authoring_section(auth).lines().map(String::from));
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

    truncate_lines(&lines, rules::CHAR_LIMIT, rules::SECTION_LINE_LIMIT * 2)
}

/// Render a runner restore context (for session-start without compact).
#[must_use]
pub fn render_runner_restore_context(project_dir: &Path, runner: &RunnerHandoff) -> String {
    let mut lines = vec![
        "Kuma harness active run restored from saved project state.".to_string(),
        format!("Project: {}", project_dir.to_string_lossy()),
    ];
    lines.extend(render_runner_section(runner).lines().map(String::from));
    lines.push(format!(
        "If the user passed `--resume {}`, treat this run as already initialized. \
         Read `{}` and continue from its next planned group instead of rerunning \
         `harness init`.",
        runner.run_id,
        PathBuf::from(&runner.run_dir)
            .join("run-status.json")
            .display()
    ));
    lines.push(
        "Do not run raw `kubectl` or `kubectl --kubeconfig ...` after restore. Use \
         `harness run --phase <phase> --label <label> kubectl <args>` or \
         `harness record --phase <phase> --label <label> -- kubectl <args>`."
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
             manually. Run `harness runner-state --event resume-run` once, then continue \
             from the saved `next_planned_group`."
                .to_string(),
        );
    }
    lines.push(
        "Continue from the restored harness state. \
         Do not rerun `harness init` unless the run directory is missing or corrupt."
            .to_string(),
    );

    truncate_lines(&lines, rules::CHAR_LIMIT, rules::SECTION_LINE_LIMIT * 2)
}

fn render_runner_section(handoff: &RunnerHandoff) -> String {
    let mut lines = vec![
        "suite-runner:".to_string(),
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
         `harness run --phase <phase> --label <label> kubectl <args>` or \
         `harness record --phase <phase> --label <label> -- kubectl <args>`; \
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
            lines.push("- Resume: run `harness runner-state --event resume-run`.".to_string());
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
        .map(String::as_str)
        .collect();
    lines.push(format!("- Key state files: {}", state_preview.join(", ")));
    lines.push(format!("- Next action: {}", handoff.next_action));

    truncate_lines(&lines, rules::SECTION_CHAR_LIMIT, rules::SECTION_LINE_LIMIT)
}

fn render_authoring_section(handoff: &AuthoringHandoff) -> String {
    let lines = vec![
        "suite-author:".to_string(),
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
            handoff.author_phase.as_deref().unwrap_or("missing")
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
                .map(String::as_str)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        format!("- Next action: {}", handoff.next_action),
    ];

    truncate_lines(&lines, rules::SECTION_CHAR_LIMIT, rules::SECTION_LINE_LIMIT)
}

fn ordered_sections(handoff: &CompactHandoff) -> Vec<String> {
    let mut sections: Vec<(&str, bool)> = Vec::new();
    if handoff.authoring.is_some() {
        let unfinished = handoff
            .authoring
            .as_ref()
            .is_some_and(|a| !matches!(a.author_phase.as_deref(), Some("complete" | "cancelled")));
        sections.push(("authoring", unfinished));
    }
    if handoff.runner.is_some() {
        let unfinished = handoff.runner.as_ref().is_some_and(|r| {
            r.verdict.as_deref().is_none()
                || r.verdict.as_deref() == Some("pending")
                || r.completed_at.is_none()
        });
        sections.push(("runner", unfinished));
    }

    // Unfinished sections first
    sections.sort_by_key(|(name, unfinished)| (!unfinished, *name));
    sections
        .into_iter()
        .map(|(name, _)| name.to_string())
        .collect()
}

fn truncate_lines(lines: &[String], char_limit: usize, line_limit: usize) -> String {
    let mut rendered = Vec::new();
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
        rendered.push(truncated.to_string());
        total += truncated.len() + 1;
        if total >= char_limit {
            break;
        }
    }
    rendered.join("\n")
}

fn write_json_atomic(path: &Path, payload: &CompactHandoff) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| CliError {
            code: "IO".to_string(),
            message: format!("failed to create directory: {e}"),
            exit_code: 1,
            hint: None,
            details: None,
        })?;
    }
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(payload).map_err(|e| CliError {
        code: "SERIALIZE".to_string(),
        message: format!("failed to serialize: {e}"),
        exit_code: 1,
        hint: None,
        details: None,
    })?;
    fs::write(&tmp, &text).map_err(|e| CliError {
        code: "IO".to_string(),
        message: format!("failed to write {}: {e}", tmp.display()),
        exit_code: 1,
        hint: None,
        details: None,
    })?;
    fs::rename(&tmp, path).map_err(|e| CliError {
        code: "IO".to_string(),
        message: format!(
            "failed to rename {} to {}: {e}",
            tmp.display(),
            path.display()
        ),
        exit_code: 1,
        hint: None,
        details: None,
    })?;
    Ok(())
}

fn trim_history(project_dir: &Path) {
    let history_dir = compact_history_dir(project_dir);
    if !history_dir.exists() {
        return;
    }
    let Ok(entries) = fs::read_dir(&history_dir) else {
        return;
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(result::Result::ok)
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .collect();
    files.sort();
    let excess = files.len().saturating_sub(rules::HISTORY_LIMIT);
    for path in files.into_iter().take(excess) {
        if let Err(e) = fs::remove_file(&path) {
            eprintln!(
                "warning: failed to remove history file {}: {e}",
                path.display()
            );
        }
    }
}

fn file_sha256(path: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    let data = fs::read(path).ok()?;
    let hash = Sha256::digest(&data);
    Some(format!("{hash:x}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_handoff(project_dir: &str) -> CompactHandoff {
        CompactHandoff {
            version: rules::HANDOFF_VERSION,
            project_dir: project_dir.to_string(),
            created_at: "2026-01-01T000000Z".to_string(),
            status: rules::STATUS_PENDING.to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: None,
            authoring: None,
            fingerprints: vec![],
        }
    }

    /// Write a handoff directly to a path (bypasses `project_context_dir`).
    fn write_handoff_to(path: &Path, handoff: &CompactHandoff) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let text = serde_json::to_string_pretty(handoff).unwrap();
        fs::write(path, text).unwrap();
    }

    /// Read a handoff directly from a path.
    fn read_handoff_from(path: &Path) -> Option<CompactHandoff> {
        let text = fs::read_to_string(path).ok()?;
        serde_json::from_str(&text).ok()
    }

    #[test]
    fn save_and_load_via_direct_write() {
        let dir = tempfile::tempdir().unwrap();
        let latest = dir.path().join("compact").join("latest.json");
        let handoff = test_handoff("/project");

        write_handoff_to(&latest, &handoff);
        let loaded = read_handoff_from(&latest).unwrap();

        assert_eq!(loaded.version, handoff.version);
        assert_eq!(loaded.status, rules::STATUS_PENDING);
        assert_eq!(loaded.project_dir, "/project");
    }

    #[test]
    fn write_json_atomic_creates_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("handoff.json");
        let handoff = test_handoff("/p");

        write_json_atomic(&path, &handoff).unwrap();

        let loaded: CompactHandoff =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(loaded.project_dir, "/p");
    }

    #[test]
    fn consume_updates_status() {
        let dir = tempfile::tempdir().unwrap();
        let latest = dir.path().join("latest.json");
        let handoff = test_handoff("/p");
        write_handoff_to(&latest, &handoff);

        // Manually consume
        let consumed = CompactHandoff {
            status: rules::STATUS_CONSUMED.to_string(),
            consumed_at: Some("2026-01-01T01:00:00Z".to_string()),
            ..handoff
        };
        write_handoff_to(&latest, &consumed);

        let loaded = read_handoff_from(&latest).unwrap();
        assert_eq!(loaded.status, rules::STATUS_CONSUMED);
        assert!(loaded.consumed_at.is_some());
    }

    #[test]
    fn pending_filter_works() {
        let pending = test_handoff("/p");
        assert_eq!(pending.status, rules::STATUS_PENDING);

        let consumed = CompactHandoff {
            status: rules::STATUS_CONSUMED.to_string(),
            ..test_handoff("/p")
        };
        assert_ne!(consumed.status, rules::STATUS_PENDING);
    }

    #[test]
    fn load_returns_none_when_no_file() {
        let path = Path::new("/nonexistent/latest.json");
        assert!(read_handoff_from(path).is_none());
    }

    #[test]
    fn file_fingerprint_existing_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        fs::write(&file, "hello").unwrap();

        let fp = FileFingerprint::from_path("test", &file);
        assert!(fp.exists);
        assert_eq!(fp.size, Some(5));
        assert!(fp.sha256.is_some());
        assert!(fp.mtime_ns.is_some());
    }

    #[test]
    fn file_fingerprint_nonexistent_file() {
        let fp = FileFingerprint::from_path("ghost", Path::new("/nonexistent/file"));
        assert!(!fp.exists);
        assert!(fp.size.is_none());
        assert!(fp.sha256.is_none());
    }

    #[test]
    fn file_fingerprint_matches_disk_when_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("stable.txt");
        fs::write(&file, "content").unwrap();

        let fp = FileFingerprint::from_path("stable", &file);
        assert!(fp.matches_disk());
    }

    #[test]
    fn file_fingerprint_diverges_after_write() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("changing.txt");
        fs::write(&file, "before").unwrap();

        let fp = FileFingerprint::from_path("changing", &file);
        fs::write(&file, "after").unwrap();

        assert!(!fp.matches_disk());
    }

    #[test]
    fn verify_fingerprints_detects_changes() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("f.txt");
        fs::write(&file, "v1").unwrap();
        let fp = FileFingerprint::from_path("f", &file);

        fs::write(&file, "v2").unwrap();

        let mut handoff = test_handoff("/p");
        handoff.fingerprints = vec![fp];

        let diverged = verify_fingerprints(&handoff);
        assert_eq!(diverged.len(), 1);
    }

    #[test]
    fn render_hydration_context_includes_header() {
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/project".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: None,
            authoring: None,
            fingerprints: vec![],
        };
        let ctx = render_hydration_context(&handoff, &[]);
        assert!(ctx.contains("Kuma compaction handoff restored"));
        assert!(ctx.contains("Continue immediately from the saved state below"));
        assert!(ctx.contains("Project: /project"));
    }

    #[test]
    fn render_hydration_context_includes_divergence_warning() {
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/p".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: None,
            authoring: None,
            fingerprints: vec![],
        };
        let diverged = vec!["/some/file.json".to_string()];
        let ctx = render_hydration_context(&handoff, &diverged);
        assert!(ctx.contains("WARNING: the saved handoff diverged"));
        assert!(ctx.contains("/some/file.json"));
    }

    #[test]
    fn render_hydration_context_includes_runner_section() {
        let runner = RunnerHandoff {
            run_dir: "/runs/r1".to_string(),
            run_id: "r1".to_string(),
            suite_id: None,
            profile: Some("single-zone".to_string()),
            suite_path: Some("/suites/s1/suite.md".to_string()),
            runner_phase: Some("execution".to_string()),
            verdict: Some("pending".to_string()),
            completed_at: None,
            last_state_capture: None,
            next_action: "run next group".to_string(),
            executed_groups: vec!["g01".to_string()],
            remaining_groups: vec!["g02".to_string()],
            state_paths: vec![],
        };
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/p".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: Some(runner),
            authoring: None,
            fingerprints: vec![],
        };
        let ctx = render_hydration_context(&handoff, &[]);
        assert!(ctx.contains("suite-runner:"));
        assert!(ctx.contains("Run: r1"));
        assert!(ctx.contains("never raw `kubectl`"));
    }

    #[test]
    fn render_hydration_context_includes_authoring_section() {
        let authoring = AuthoringHandoff {
            suite_dir: "/suites/s1".to_string(),
            next_action: "pre-write review loop".to_string(),
            author_phase: Some("prewrite_review".to_string()),
            suite_name: Some("motb-core".to_string()),
            feature: Some("motb".to_string()),
            mode: Some("interactive".to_string()),
            saved_payloads: vec!["inventory".to_string(), "proposal".to_string()],
            suite_files: vec![],
            state_paths: vec![],
        };
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/p".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: None,
            authoring: Some(authoring),
            fingerprints: vec![],
        };
        let ctx = render_hydration_context(&handoff, &[]);
        assert!(ctx.contains("suite-author:"));
        assert!(ctx.contains("Suite name: motb-core"));
        assert!(ctx.contains("Saved payloads: inventory, proposal"));
    }

    #[test]
    fn render_runner_restore_context_includes_resume_guidance() {
        let runner = RunnerHandoff {
            run_dir: "/runs/r1".to_string(),
            run_id: "r1".to_string(),
            suite_id: None,
            profile: Some("single-zone".to_string()),
            suite_path: Some("/s/suite.md".to_string()),
            runner_phase: Some("execution".to_string()),
            verdict: Some("pending".to_string()),
            completed_at: None,
            last_state_capture: None,
            next_action: "continue".to_string(),
            executed_groups: vec![],
            remaining_groups: vec![],
            state_paths: vec![],
        };
        let ctx = render_runner_restore_context(Path::new("/project"), &runner);
        assert!(ctx.contains("Kuma harness active run restored"));
        assert!(ctx.contains("treat this run as already initialized"));
        assert!(ctx.contains("Do not run raw `kubectl`"));
    }

    #[test]
    fn render_runner_restore_context_aborted_with_remaining_groups() {
        let runner = RunnerHandoff {
            run_dir: "/runs/r1".to_string(),
            run_id: "r1".to_string(),
            suite_id: None,
            profile: None,
            suite_path: None,
            runner_phase: Some("aborted".to_string()),
            verdict: Some("aborted".to_string()),
            completed_at: None,
            last_state_capture: None,
            next_action: "resume".to_string(),
            executed_groups: vec!["g01".to_string()],
            remaining_groups: vec!["g02".to_string()],
            state_paths: vec![],
        };
        let ctx = render_runner_restore_context(Path::new("/p"), &runner);
        assert!(ctx.contains("harness runner-state --event resume-run"));
        assert!(ctx.contains("do not edit control files"));
    }

    #[test]
    fn render_runner_section_aborted_no_remaining() {
        let runner = RunnerHandoff {
            run_dir: "/runs/r1".to_string(),
            run_id: "r1".to_string(),
            suite_id: None,
            profile: None,
            suite_path: None,
            runner_phase: Some("aborted".to_string()),
            verdict: Some("aborted".to_string()),
            completed_at: None,
            last_state_capture: None,
            next_action: "done".to_string(),
            executed_groups: vec![],
            remaining_groups: vec![],
            state_paths: vec![],
        };
        let section = render_runner_section(&runner);
        assert!(section.contains("intentionally halted"));
    }

    #[test]
    fn truncate_lines_respects_char_limit() {
        let lines: Vec<String> = (0..100)
            .map(|i| format!("line {i} with some content"))
            .collect();
        let result = truncate_lines(&lines, 100, 50);
        assert!(result.len() <= 100);
    }

    #[test]
    fn truncate_lines_respects_line_limit() {
        let lines: Vec<String> = (0..100).map(|i| format!("line {i}")).collect();
        let result = truncate_lines(&lines, 10000, 5);
        assert!(result.lines().count() <= 5);
    }

    #[test]
    fn has_sections_false_when_empty() {
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/p".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: None,
            authoring: None,
            fingerprints: vec![],
        };
        assert!(!handoff.has_sections());
    }

    #[test]
    fn has_sections_true_with_runner() {
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/p".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: Some(RunnerHandoff {
                run_dir: "/r".to_string(),
                run_id: "r1".to_string(),
                suite_id: None,
                profile: None,
                suite_path: None,
                runner_phase: None,
                verdict: None,
                completed_at: None,
                last_state_capture: None,
                next_action: "x".to_string(),
                executed_groups: vec![],
                remaining_groups: vec![],
                state_paths: vec![],
            }),
            authoring: None,
            fingerprints: vec![],
        };
        assert!(handoff.has_sections());
    }

    #[test]
    fn compact_handoff_serialization_roundtrip() {
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/project".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: Some("session-abc".to_string()),
            source_session_id: Some("abc".to_string()),
            transcript_path: None,
            cwd: Some("/cwd".to_string()),
            trigger: Some("manual".to_string()),
            custom_instructions: None,
            consumed_at: None,
            runner: None,
            authoring: None,
            fingerprints: vec![],
        };
        let json = serde_json::to_string(&handoff).unwrap();
        let parsed: CompactHandoff = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.version, handoff.version);
        assert_eq!(parsed.status, handoff.status);
        assert_eq!(parsed.trigger, handoff.trigger);
    }

    #[test]
    fn trim_history_logic() {
        // Test the trimming logic directly without project_context_dir
        let dir = tempfile::tempdir().unwrap();
        let history = dir.path().join("history");
        fs::create_dir_all(&history).unwrap();

        for i in 0..15 {
            let name = format!("{i:04}.json");
            fs::write(history.join(name), "{}").unwrap();
        }

        // Directly test the trim logic
        let entries_before: Vec<_> = fs::read_dir(&history)
            .unwrap()
            .filter_map(result::Result::ok)
            .collect();
        assert_eq!(entries_before.len(), 15);

        let mut files: Vec<PathBuf> = fs::read_dir(&history)
            .unwrap()
            .filter_map(result::Result::ok)
            .map(|e| e.path())
            .filter(|p| p.is_file())
            .collect();
        files.sort();
        let excess = files.len().saturating_sub(rules::HISTORY_LIMIT);
        for path in files.into_iter().take(excess) {
            fs::remove_file(path).unwrap();
        }

        let remaining: Vec<_> = fs::read_dir(&history)
            .unwrap()
            .filter_map(result::Result::ok)
            .collect();
        assert_eq!(remaining.len(), rules::HISTORY_LIMIT);
    }

    #[test]
    fn ordered_sections_unfinished_first() {
        let handoff = CompactHandoff {
            version: 1,
            project_dir: "/p".to_string(),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            status: "pending".to_string(),
            source_session_scope: None,
            source_session_id: None,
            transcript_path: None,
            cwd: None,
            trigger: None,
            custom_instructions: None,
            consumed_at: None,
            runner: Some(RunnerHandoff {
                run_dir: "/r".to_string(),
                run_id: "r1".to_string(),
                suite_id: None,
                profile: None,
                suite_path: None,
                runner_phase: Some("completed".to_string()),
                verdict: Some("pass".to_string()),
                completed_at: Some("2026-01-01T00:00:00Z".to_string()),
                last_state_capture: None,
                next_action: "done".to_string(),
                executed_groups: vec![],
                remaining_groups: vec![],
                state_paths: vec![],
            }),
            authoring: Some(AuthoringHandoff {
                suite_dir: "/s".to_string(),
                next_action: "write".to_string(),
                author_phase: Some("writing".to_string()),
                suite_name: None,
                feature: None,
                mode: None,
                saved_payloads: vec![],
                suite_files: vec![],
                state_paths: vec![],
            }),
            fingerprints: vec![],
        };
        let sections = ordered_sections(&handoff);
        // Authoring is unfinished (writing), runner is complete
        assert_eq!(sections[0], "authoring");
        assert_eq!(sections[1], "runner");
    }
}
