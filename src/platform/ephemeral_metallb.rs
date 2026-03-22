use std::fs;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};

const STATE_FILE: &str = "ephemeral-metallb-templates.json";

/// State path for tracked ephemeral `MetalLB` resources.
#[must_use]
pub fn state_path(run_dir: &Path) -> PathBuf {
    run_dir.join("state").join(STATE_FILE)
}

/// Cleanup tracked generated `MetalLB` resource files.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn cleanup_resources(run_dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    let entries = load_entries(Some(run_dir))?;
    if entries.is_empty() {
        return Ok(vec![]);
    }

    let mut removed = Vec::new();
    for entry in &entries {
        if let Some(tp) = entry.get("template_path").and_then(|v| v.as_str()) {
            let resource = PathBuf::from(tp);
            if resource.exists() {
                fs::remove_file(&resource)?;
                removed.push(resource);
            }
        }
    }

    Ok(removed)
}

fn load_entries(run_dir: Option<&Path>) -> Result<Vec<serde_json::Value>, CliError> {
    let Some(rd) = run_dir else {
        return Ok(vec![]);
    };
    let path = state_path(rd);
    if !path.is_file() {
        return Ok(vec![]);
    }
    let text = fs::read_to_string(&path)
        .map_err(|e| CliErrorKind::io(format!("{}: {e}", path.display())))?;
    let payload: serde_json::Value = serde_json::from_str(&text).map_err(|e| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(e.to_string())
    })?;
    Ok(payload
        .get("entries")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default())
}

#[cfg(test)]
mod tests;
