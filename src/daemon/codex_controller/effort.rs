//! Effort-level validation for Codex runs.
//!
//! Split from `handle.rs` to keep the file under the repo source-length limit.

use crate::agents::runtime::models;
use crate::errors::{CliError, CliErrorKind};

/// Validate a codex effort level against the requested model's catalog entry.
/// Falls back to the codex default model when no model was specified.
///
/// # Errors
/// Returns a workflow parse error when the catalog is missing, the model id
/// is unknown, the model does not support effort, or the requested level is
/// not in the model's allowed `effort_values`.
pub(super) fn validate_codex_effort(
    requested_model: Option<&str>,
    effort: &str,
) -> Result<(), CliError> {
    let Some(catalog) = models::catalog_for("codex") else {
        return Err(CliErrorKind::workflow_parse("codex catalog unavailable").into());
    };
    let model_id = requested_model.unwrap_or(catalog.default.as_str());
    let Some(entry) = catalog.models.iter().find(|entry| entry.id == model_id) else {
        return Err(CliErrorKind::workflow_parse(format!(
            "model '{model_id}' is not valid for runtime 'codex'"
        ))
        .into());
    };
    if !entry.supports_effort() {
        return Err(CliErrorKind::workflow_parse(format!(
            "model '{model_id}' does not support an effort level"
        ))
        .into());
    }
    if !entry.effort_values.iter().any(|value| value == effort) {
        return Err(CliErrorKind::workflow_parse(format!(
            "effort '{effort}' is not valid for model '{model_id}': valid values are {}",
            entry.effort_values.join(", ")
        ))
        .into());
    }
    Ok(())
}
