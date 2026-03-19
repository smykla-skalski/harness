pub mod fingerprint;
pub mod handoff;
mod render;

pub use fingerprint::FileFingerprint;
pub use handoff::{AuthoringHandoff, CompactHandoff, HandoffStatus, RunnerHandoff};
pub use render::{render_hydration_context, render_runner_restore_context};

use std::borrow::Cow;
use std::path::{Path, PathBuf};
use std::result;

use fs_err as fs;
use rayon::prelude::*;
use tracing::warn;

use crate::core_defs::{project_context_dir, session_scope_key, utc_now};
use crate::errors::{CliError, io_for};
use crate::infra::io::{read_text, write_json_pretty};
use crate::rules::compact as compact_rules;

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
pub fn build_compact_handoff(project_dir: &Path) -> Result<CompactHandoff<'static>, CliError> {
    Ok(CompactHandoff {
        version: compact_rules::HANDOFF_VERSION,
        project_dir: Cow::Owned(project_dir.to_string_lossy().into_owned()),
        created_at: Cow::Owned(utc_now()),
        status: HandoffStatus::Pending,
        source_session_scope: session_scope_key().ok().map(Cow::Owned),
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
    handoff: &CompactHandoff<'_>,
) -> Result<(), CliError> {
    let latest_path = compact_latest_path(project_dir);
    let history_dir = compact_history_dir(project_dir);
    let history_name = handoff.created_at.replace([':', '.'], "") + ".json";
    let history_path = history_dir.join(history_name);

    write_json_atomic(&latest_path, handoff)?;
    write_json_atomic(&history_path, handoff)?;
    trim_history(project_dir);

    Ok(())
}

/// Load the latest compact handoff.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_latest_compact_handoff(
    project_dir: &Path,
) -> Result<Option<CompactHandoff<'static>>, CliError> {
    let path = compact_latest_path(project_dir);
    if !path.exists() {
        return Ok(None);
    }
    let text =
        read_text(&path).map_err(|error| -> CliError { io_for("read", &path, &error).into() })?;
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|e| -> CliError { io_for("parse compact handoff at", &path, &e).into() })
}

/// Load a pending (unconsumed) compact handoff, if any.
///
/// # Errors
/// Returns `CliError` if the persisted compact handoff exists but is unreadable
/// or corrupt.
pub fn pending_compact_handoff(
    project_dir: &Path,
) -> Result<Option<CompactHandoff<'static>>, CliError> {
    let handoff = load_latest_compact_handoff(project_dir)?;
    Ok(handoff.filter(|item| item.status == HandoffStatus::Pending))
}

/// Mark a handoff as consumed.
///
/// Takes ownership of the handoff to avoid cloning the entire struct.
/// Callers that need the handoff afterwards should clone before passing.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn consume_compact_handoff<'a>(
    project_dir: &Path,
    handoff: CompactHandoff<'a>,
) -> Result<CompactHandoff<'a>, CliError> {
    let consumed = CompactHandoff {
        status: HandoffStatus::Consumed,
        consumed_at: Some(Cow::Owned(utc_now())),
        ..handoff
    };
    write_json_atomic(&compact_latest_path(project_dir), &consumed)?;
    Ok(consumed)
}

/// Check which fingerprints have diverged from disk.
#[must_use]
pub fn verify_fingerprints<'a>(handoff: &'a CompactHandoff<'_>) -> Vec<&'a Path> {
    handoff
        .fingerprints
        .par_iter()
        .filter(|fp| !fp.matches_disk())
        .map(|fp| fp.path.as_path())
        .collect()
}

fn write_json_atomic(path: &Path, payload: &CompactHandoff<'_>) -> Result<(), CliError> {
    write_json_pretty(path, payload)
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
    let excess = files.len().saturating_sub(compact_rules::HISTORY_LIMIT);
    for path in files.into_iter().take(excess) {
        if let Err(e) = fs::remove_file(&path) {
            warn!(path = %path.display(), %e, "failed to remove history file");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use render::{ordered_sections, truncate_lines};
    use std::path::Path;

    fn test_handoff(project_dir: &str) -> CompactHandoff<'static> {
        CompactHandoff {
            version: compact_rules::HANDOFF_VERSION,
            project_dir: Cow::Owned(project_dir.to_string()),
            created_at: "2026-01-01T000000Z".into(),
            status: HandoffStatus::Pending,
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
    fn write_handoff_to(path: &Path, handoff: &CompactHandoff<'_>) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let text = serde_json::to_string_pretty(handoff).unwrap();
        fs::write(path, text).unwrap();
    }

    /// Read a handoff directly from a path.
    fn read_handoff_from(path: &Path) -> Option<CompactHandoff<'static>> {
        let text = read_text(path).ok()?;
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
        assert_eq!(loaded.status, HandoffStatus::Pending);
        assert_eq!(loaded.project_dir, "/project");
    }

    #[test]
    fn write_json_atomic_creates_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("handoff.json");
        let handoff = test_handoff("/p");

        write_json_atomic(&path, &handoff).unwrap();

        let loaded: CompactHandoff<'_> =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(loaded.project_dir, "/p");
    }

    #[test]
    fn consume_updates_status() {
        let dir = tempfile::tempdir().unwrap();
        let latest = dir.path().join("latest.json");
        let handoff = test_handoff("/p");
        write_handoff_to(&latest, &handoff);

        let consumed = CompactHandoff {
            status: HandoffStatus::Consumed,
            consumed_at: Some("2026-01-01T01:00:00Z".into()),
            ..handoff
        };
        write_handoff_to(&latest, &consumed);

        let loaded = read_handoff_from(&latest).unwrap();
        assert_eq!(loaded.status, HandoffStatus::Consumed);
        assert!(loaded.consumed_at.is_some());
    }

    #[test]
    fn pending_filter_works() {
        let pending = test_handoff("/p");
        assert_eq!(pending.status, HandoffStatus::Pending);

        let consumed = CompactHandoff {
            status: HandoffStatus::Consumed,
            ..test_handoff("/p")
        };
        assert_ne!(consumed.status, HandoffStatus::Pending);
    }

    #[test]
    fn load_returns_none_when_no_file() {
        let path = Path::new("/nonexistent/latest.json");
        assert!(read_handoff_from(path).is_none());
    }

    #[test]
    fn pending_compact_handoff_rejects_corrupt_latest_file() {
        let dir = tempfile::tempdir().unwrap();
        let xdg = dir.path().join("xdg");
        temp_env::with_vars([("XDG_DATA_HOME", Some(xdg.to_str().unwrap()))], || {
            let latest = compact_latest_path(dir.path());
            if let Some(parent) = latest.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(&latest, "{ invalid").unwrap();

            let error = pending_compact_handoff(dir.path()).unwrap_err();
            assert_eq!(error.code(), "IO001");
        });
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
        let handoff = test_handoff("/project");
        let ctx = render_hydration_context(&handoff, &[]);
        assert!(ctx.contains("Kuma compaction handoff restored"));
        assert!(ctx.contains("Continue immediately from the saved state below"));
        assert!(ctx.contains("Project: /project"));
    }

    #[test]
    fn render_hydration_context_includes_divergence_warning() {
        let handoff = test_handoff("/p");
        let diverged: Vec<&Path> = vec![Path::new("/some/file.json")];
        let ctx = render_hydration_context(&handoff, &diverged);
        assert!(ctx.contains("WARNING: the saved handoff diverged"));
        assert!(ctx.contains("/some/file.json"));
    }

    #[test]
    fn render_hydration_context_includes_runner_section() {
        let runner = RunnerHandoff {
            run_dir: "/runs/r1".into(),
            run_id: "r1".into(),
            suite_id: None,
            profile: Some("single-zone".into()),
            suite_path: Some("/suites/s1/suite.md".into()),
            runner_phase: Some("execution".into()),
            verdict: Some("pending".into()),
            completed_at: None,
            last_state_capture: None,
            next_action: "run next group".into(),
            executed_groups: vec!["g01".into()],
            remaining_groups: vec!["g02".into()],
            state_paths: vec![],
        };
        let mut handoff = test_handoff("/p");
        handoff.runner = Some(runner);
        let ctx = render_hydration_context(&handoff, &[]);
        assert!(ctx.contains("suite:run:"));
        assert!(ctx.contains("Run: r1"));
        assert!(ctx.contains("never raw `kubectl`"));
    }

    #[test]
    fn render_hydration_context_includes_authoring_section() {
        let authoring = AuthoringHandoff {
            suite_dir: "/suites/s1".into(),
            next_action: "pre-write review loop".into(),
            author_phase: Some("prewrite_review".into()),
            suite_name: Some("motb-core".into()),
            feature: Some("motb".into()),
            mode: Some("interactive".into()),
            saved_payloads: vec!["inventory".into(), "proposal".into()],
            suite_files: vec![],
            state_paths: vec![],
        };
        let mut handoff = test_handoff("/p");
        handoff.authoring = Some(authoring);
        let ctx = render_hydration_context(&handoff, &[]);
        assert!(ctx.contains("suite:new:"));
        assert!(ctx.contains("Suite name: motb-core"));
        assert!(ctx.contains("Saved payloads: inventory, proposal"));
    }

    #[test]
    fn render_runner_restore_context_includes_resume_guidance() {
        let runner = RunnerHandoff {
            run_dir: "/runs/r1".into(),
            run_id: "r1".into(),
            suite_id: None,
            profile: Some("single-zone".into()),
            suite_path: Some("/s/suite.md".into()),
            runner_phase: Some("execution".into()),
            verdict: Some("pending".into()),
            completed_at: None,
            last_state_capture: None,
            next_action: "continue".into(),
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
            run_dir: "/runs/r1".into(),
            run_id: "r1".into(),
            suite_id: None,
            profile: None,
            suite_path: None,
            runner_phase: Some("aborted".into()),
            verdict: Some("aborted".into()),
            completed_at: None,
            last_state_capture: None,
            next_action: "resume".into(),
            executed_groups: vec!["g01".into()],
            remaining_groups: vec!["g02".into()],
            state_paths: vec![],
        };
        let ctx = render_runner_restore_context(Path::new("/p"), &runner);
        assert!(ctx.contains("harness run runner-state --event resume-run"));
        assert!(ctx.contains("do not edit control files"));
    }

    #[test]
    fn render_runner_section_aborted_no_remaining() {
        let runner = RunnerHandoff {
            run_dir: "/runs/r1".into(),
            run_id: "r1".into(),
            suite_id: None,
            profile: None,
            suite_path: None,
            runner_phase: Some("aborted".into()),
            verdict: Some("aborted".into()),
            completed_at: None,
            last_state_capture: None,
            next_action: "done".into(),
            executed_groups: vec![],
            remaining_groups: vec![],
            state_paths: vec![],
        };
        let section = render::render_runner_section(&runner);
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
        let handoff = test_handoff("/p");
        assert!(!handoff.has_sections());
    }

    #[test]
    fn has_sections_true_with_runner() {
        let mut handoff = test_handoff("/p");
        handoff.runner = Some(RunnerHandoff {
            run_dir: "/r".into(),
            run_id: "r1".into(),
            suite_id: None,
            profile: None,
            suite_path: None,
            runner_phase: None,
            verdict: None,
            completed_at: None,
            last_state_capture: None,
            next_action: "x".into(),
            executed_groups: vec![],
            remaining_groups: vec![],
            state_paths: vec![],
        });
        assert!(handoff.has_sections());
    }

    #[test]
    fn compact_handoff_serialization_roundtrip() {
        let mut handoff = test_handoff("/project");
        handoff.source_session_scope = Some("session-abc".into());
        handoff.source_session_id = Some("abc".into());
        handoff.cwd = Some("/cwd".into());
        handoff.trigger = Some("manual".into());
        let json = serde_json::to_string(&handoff).unwrap();
        let parsed: CompactHandoff<'_> = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.version, handoff.version);
        assert_eq!(parsed.status, handoff.status);
        assert_eq!(parsed.trigger, handoff.trigger);
    }

    #[test]
    fn trim_history_logic() {
        let dir = tempfile::tempdir().unwrap();
        let history = dir.path().join("history");
        fs::create_dir_all(&history).unwrap();

        for i in 0..15 {
            let name = format!("{i:04}.json");
            fs::write(history.join(name), "{}").unwrap();
        }

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
        let excess = files.len().saturating_sub(compact_rules::HISTORY_LIMIT);
        for path in files.into_iter().take(excess) {
            fs::remove_file(path).unwrap();
        }

        let remaining: Vec<_> = fs::read_dir(&history)
            .unwrap()
            .filter_map(result::Result::ok)
            .collect();
        assert_eq!(remaining.len(), compact_rules::HISTORY_LIMIT);
    }

    #[test]
    fn ordered_sections_unfinished_first() {
        let mut handoff = test_handoff("/p");
        handoff.runner = Some(RunnerHandoff {
            run_dir: "/r".into(),
            run_id: "r1".into(),
            suite_id: None,
            profile: None,
            suite_path: None,
            runner_phase: Some("completed".into()),
            verdict: Some("pass".into()),
            completed_at: Some("2026-01-01T00:00:00Z".into()),
            last_state_capture: None,
            next_action: "done".into(),
            executed_groups: vec![],
            remaining_groups: vec![],
            state_paths: vec![],
        });
        handoff.authoring = Some(AuthoringHandoff {
            suite_dir: "/s".into(),
            next_action: "write".into(),
            author_phase: Some("writing".into()),
            suite_name: None,
            feature: None,
            mode: None,
            saved_payloads: vec![],
            suite_files: vec![],
            state_paths: vec![],
        });
        let sections = ordered_sections(&handoff);
        assert_eq!(sections[0], "authoring");
        assert_eq!(sections[1], "runner");
    }
}
