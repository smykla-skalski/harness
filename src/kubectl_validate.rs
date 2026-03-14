use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// Decision about kubectl-validate installation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KubectlValidateDecision {
    Installed,
    Declined,
}

/// Persisted state for kubectl-validate decision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KubectlValidateState {
    pub schema_version: u32,
    pub decision: KubectlValidateDecision,
    pub decided_at: String,
    #[serde(default)]
    pub binary_path: Option<String>,
}

/// Path to the kubectl-validate state file.
#[must_use]
pub fn kubectl_validate_state_path() -> PathBuf {
    todo!()
}

/// Read kubectl-validate state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_kubectl_validate_state() -> Result<Option<KubectlValidateState>, CliError> {
    todo!()
}

/// Check if the install prompt is needed.
#[must_use]
pub fn kubectl_validate_prompt_required() -> bool {
    todo!()
}

/// Resolve the kubectl-validate binary path.
#[must_use]
pub fn resolve_kubectl_validate_binary() -> Option<PathBuf> {
    todo!()
}

#[cfg(test)]
mod tests {}
