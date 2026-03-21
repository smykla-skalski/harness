use crate::errors::{CliError, CliErrorKind};

#[path = "capabilities/data.rs"]
mod data;
#[path = "capabilities/model.rs"]
mod model;

use data::{authoring, cluster_topologies, features, platforms};
use model::CapabilitiesReport;

/// Report harness capabilities as structured JSON for skill planning.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capabilities() -> Result<i32, CliError> {
    let caps = CapabilitiesReport {
        authoring: authoring(),
        cluster_topologies: cluster_topologies(),
        features: features(),
        platforms: platforms(),
    };
    let output = serde_json::to_string_pretty(&caps)
        .map_err(|e| CliErrorKind::io(format!("json serialize: {e}")))?;
    println!("{output}");
    Ok(0)
}

#[cfg(test)]
mod tests;
