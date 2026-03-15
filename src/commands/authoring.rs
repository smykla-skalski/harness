use std::fs;
use std::path::{Path, PathBuf};

use crate::authoring::{
    authoring_workspace_dir, begin_authoring_session, require_authoring_session,
};
use crate::authoring_validate::{authoring_validation_repo_root, validate_suite_author_paths};
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::io::{ensure_dir, is_safe_name, read_text, write_text};
use crate::workflow::author::{
    ApprovalMode, AuthorDraftState, AuthorPhase, AuthorReviewState, AuthorSessionInfo,
    AuthorWorkflowState, write_author_state,
};

// =========================================================================
// begin
// =========================================================================

/// Begin a suite:new workspace session.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn begin(
    repo_root: &str,
    feature: &str,
    mode: &str,
    suite_dir: &str,
    suite_name: &str,
) -> Result<i32, CliError> {
    begin_authoring_session(
        Path::new(repo_root),
        feature,
        mode,
        Path::new(suite_dir),
        suite_name,
    )?;
    Ok(0)
}

// =========================================================================
// save
// =========================================================================

fn read_input(input: Option<&str>, payload: Option<&str>) -> Result<String, CliError> {
    if let Some(text) = payload {
        if text.trim().is_empty() {
            return Err(CliErrorKind::AuthoringPayloadMissing.into());
        }
        return Ok(text.to_string());
    }
    if let Some(path) = input {
        if path == "-" {
            return Err(CliErrorKind::AuthoringPayloadMissing.into());
        }
        return read_text(Path::new(path));
    }
    Err(CliErrorKind::AuthoringPayloadMissing.into())
}

fn parse_payload(text: &str, kind: &str) -> Result<serde_json::Value, CliError> {
    serde_json::from_str(text).map_err(|e| {
        CliErrorKind::authoring_payload_invalid(kind.to_string(), e.to_string()).into()
    })
}

/// Save a suite:new payload.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn save(kind: &str, payload: Option<&str>, input: Option<&str>) -> Result<i32, CliError> {
    if !is_safe_name(kind) {
        return Err(CliErrorKind::unsafe_name(kind.to_string()).into());
    }

    let _session = require_authoring_session()?;
    let text = read_input(input, payload)?;
    let value = parse_payload(&text, kind)?;

    let workspace = authoring_workspace_dir()?;
    ensure_dir(&workspace)?;
    let path = workspace.join(format!("{kind}.json"));
    let json = serde_json::to_string_pretty(&value).unwrap_or_default();
    write_text(&path, &json)?;

    Ok(0)
}

// =========================================================================
// show
// =========================================================================

/// Show saved suite:new payloads.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn show(kind: &str) -> Result<i32, CliError> {
    if !is_safe_name(kind) {
        return Err(CliErrorKind::unsafe_name(kind.to_string()).into());
    }

    let _session = require_authoring_session()?;
    let workspace = authoring_workspace_dir()?;
    let path = workspace.join(format!("{kind}.json"));

    if !path.exists() {
        return Err(CliErrorKind::authoring_show_kind_missing(kind.to_string()).into());
    }

    let text = read_text(&path)?;
    // Parse and re-serialize for consistent pretty-printed output
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|e| {
        CliError::from(CliErrorKind::authoring_payload_invalid(
            kind.to_string(),
            e.to_string(),
        ))
    })?;
    println!(
        "{}",
        serde_json::to_string_pretty(&value).unwrap_or_default()
    );
    Ok(0)
}

// =========================================================================
// reset
// =========================================================================

/// Reset suite:new workspace.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn reset() -> Result<i32, CliError> {
    let workspace = authoring_workspace_dir()?;
    if workspace.exists() {
        fs::remove_dir_all(&workspace)?;
    }
    Ok(0)
}

// =========================================================================
// validate
// =========================================================================

/// Validate authored manifests against local CRDs.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn validate(paths: &[String], repo_root: Option<&str>) -> Result<i32, CliError> {
    let path_refs: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    let path_slices: Vec<&Path> = path_refs.iter().map(PathBuf::as_path).collect();

    let root = authoring_validation_repo_root(repo_root, &path_slices)?;

    let validated = validate_suite_author_paths(&path_slices, &root, false)?;

    for label in &validated {
        println!("{label}");
    }
    Ok(0)
}

// =========================================================================
// approval_begin
// =========================================================================

/// Begin suite:new approval flow.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn approval_begin(mode: &str, suite_dir: Option<&str>) -> Result<i32, CliError> {
    let approval_mode = match mode {
        "interactive" => ApprovalMode::Interactive,
        "bypass" => ApprovalMode::Bypass,
        _ => {
            return Err(CliErrorKind::usage_error(cow!("invalid approval mode: {mode}")).into());
        }
    };

    let initial_phase = if approval_mode == ApprovalMode::Bypass {
        AuthorPhase::Writing
    } else {
        AuthorPhase::Discovery
    };

    let state = AuthorWorkflowState {
        schema_version: 1,
        mode: approval_mode,
        phase: initial_phase,
        session: AuthorSessionInfo {
            repo_root: None,
            feature: None,
            suite_name: None,
            suite_dir: suite_dir.map(String::from),
        },
        review: AuthorReviewState {
            gate: None,
            awaiting_answer: false,
            round: 0,
            last_answer: None,
        },
        draft: AuthorDraftState {
            suite_tree_written: false,
            written_paths: vec![],
        },
        updated_at: utc_now(),
        transition_count: 0,
        last_event: Some("ApprovalFlowStarted".to_string()),
    };

    write_author_state(&state)?;
    Ok(0)
}
