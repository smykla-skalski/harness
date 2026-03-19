use std::fs;
use std::io::{self, IsTerminal, Read};
use std::path::{Path, PathBuf};

use crate::authoring::{
    ApprovalMode, AuthorWorkflowState, AuthoringSession, authoring_validation_repo_root,
    authoring_workspace_dir, begin_authoring_session, load_authoring_session,
    require_authoring_session, validate_suite_author_paths, write_author_state,
};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{ensure_dir, is_safe_name, read_text, write_text};
use crate::workspace::utc_now;

/// Application boundary for authoring use cases.
#[derive(Debug, Default, Clone, Copy)]
pub struct AuthoringApplication;

/// Response shape for viewing saved authoring payloads.
#[derive(Debug, Clone, PartialEq)]
pub struct AuthoringPayloadView {
    pub kind: String,
    pub found: bool,
    pub value: Option<serde_json::Value>,
}

impl AuthoringApplication {
    /// Begin a suite authoring session.
    ///
    /// # Errors
    /// Returns `CliError` on persistence or path failures.
    pub fn begin_session(
        repo_root: &str,
        feature: &str,
        mode: &str,
        suite_dir: &str,
        suite_name: &str,
    ) -> Result<AuthoringSession, CliError> {
        begin_authoring_session(
            Path::new(repo_root),
            feature,
            mode,
            Path::new(suite_dir),
            suite_name,
        )
    }

    /// Begin the approval-state workflow for authoring.
    ///
    /// # Errors
    /// Returns `CliError` when the requested mode is invalid or persistence fails.
    pub fn begin_approval_flow(mode: &str, suite_dir: Option<&str>) -> Result<(), CliError> {
        let approval_mode = match mode {
            "interactive" => ApprovalMode::Interactive,
            "bypass" => ApprovalMode::Bypass,
            _ => {
                return Err(
                    CliErrorKind::usage_error(format!("invalid approval mode: {mode}")).into(),
                );
            }
        };

        let state = AuthorWorkflowState::new(approval_mode, suite_dir.map(String::from), utc_now());
        write_author_state(&state)?;
        Ok(())
    }

    /// Clear the authoring workspace.
    ///
    /// # Errors
    /// Returns `CliError` on filesystem failures.
    pub fn reset_workspace() -> Result<(), CliError> {
        let workspace = authoring_workspace_dir()?;
        if workspace.exists() {
            fs::remove_dir_all(&workspace)?;
        }
        Ok(())
    }

    /// Save an authoring payload into the session workspace.
    ///
    /// # Errors
    /// Returns `CliError` on validation, parsing, or IO failures.
    pub fn save_payload(
        kind: &str,
        payload: Option<&str>,
        input: Option<&str>,
    ) -> Result<(), CliError> {
        if !is_safe_name(kind) {
            return Err(CliErrorKind::unsafe_name(kind.to_string()).into());
        }

        let _session = require_authoring_session()?;
        let text = read_input(input, payload)?;
        let value = parse_payload(&text, kind)?;

        let workspace = authoring_workspace_dir()?;
        ensure_dir(&workspace)?;
        let path = workspace.join(format!("{kind}.json"));
        let json = serde_json::to_string_pretty(&value)
            .map_err(|e| CliErrorKind::serialize(format!("save {kind}: {e}")))?;
        write_text(&path, &json)?;
        Ok(())
    }

    /// Load a saved authoring payload for display.
    ///
    /// # Errors
    /// Returns `CliError` on IO or JSON failures.
    pub fn show_payload(kind: &str) -> Result<AuthoringPayloadView, CliError> {
        if !is_safe_name(kind) {
            return Err(CliErrorKind::unsafe_name(kind.to_string()).into());
        }

        if load_authoring_session()?.is_none() {
            return Ok(AuthoringPayloadView {
                kind: kind.to_string(),
                found: false,
                value: None,
            });
        }

        let workspace = authoring_workspace_dir()?;
        let path = workspace.join(format!("{kind}.json"));
        if !path.exists() {
            return Ok(AuthoringPayloadView {
                kind: kind.to_string(),
                found: false,
                value: None,
            });
        }

        let text = read_text(&path)?;
        let value = serde_json::from_str(&text).map_err(|e| {
            CliError::from(CliErrorKind::authoring_payload_invalid(
                kind.to_string(),
                e.to_string(),
            ))
        })?;
        Ok(AuthoringPayloadView {
            kind: kind.to_string(),
            found: true,
            value: Some(value),
        })
    }

    /// Validate authored manifests against checked-in CRDs.
    ///
    /// # Errors
    /// Returns `CliError` on path resolution or validation failures.
    pub fn validate_paths(
        paths: &[String],
        repo_root: Option<&str>,
    ) -> Result<Vec<String>, CliError> {
        let path_refs: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
        let path_slices: Vec<&Path> = path_refs.iter().map(PathBuf::as_path).collect();
        let root = authoring_validation_repo_root(repo_root, &path_slices)?;
        validate_suite_author_paths(&path_slices, &root, false)
    }
}

fn read_input(input: Option<&str>, payload: Option<&str>) -> Result<String, CliError> {
    if let Some(text) = payload {
        if text.trim().is_empty() {
            return Err(CliErrorKind::AuthoringPayloadMissing.into());
        }
        return Ok(text.to_string());
    }
    if let Some(path) = input {
        if path == "-" {
            return read_stdin();
        }
        return read_text(Path::new(path));
    }
    if !io::stdin().is_terminal() {
        return read_stdin();
    }
    Err(CliErrorKind::AuthoringPayloadMissing.into())
}

fn read_stdin() -> Result<String, CliError> {
    let mut text = String::new();
    io::stdin()
        .read_to_string(&mut text)
        .map_err(|_| CliError::from(CliErrorKind::AuthoringPayloadMissing))?;
    if text.trim().is_empty() {
        return Err(CliErrorKind::AuthoringPayloadMissing.into());
    }
    Ok(text)
}

fn parse_payload(text: &str, kind: &str) -> Result<serde_json::Value, CliError> {
    if let Ok(value) = serde_json::from_str(text) {
        return Ok(value);
    }
    let sanitized = sanitize_payload(text);
    serde_json::from_str(&sanitized).map_err(|e| {
        CliErrorKind::authoring_payload_invalid(kind.to_string(), e.to_string()).into()
    })
}

fn sanitize_payload(text: &str) -> String {
    let mut sanitized = text.trim().to_string();
    if let Some(rest) = sanitized.strip_prefix("<json>") {
        sanitized = rest.to_string();
    }
    if let Some(rest) = sanitized.strip_suffix("</json>") {
        sanitized = rest.to_string();
    }
    sanitized = sanitized.replace("\\n", "\n");
    sanitized = sanitized.replace("\\\"", "\"");
    sanitized.trim().to_string()
}
