use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use harness_kernel::errors::{CliError, CliErrorKind};

#[path = "capabilities/data.rs"]
mod data;
#[path = "capabilities/model.rs"]
mod model;
#[path = "capabilities/readiness/mod.rs"]
mod readiness;

use data::features;
use model::CapabilitiesReport;

impl Execute for CapabilitiesArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        capabilities(self.project_dir.as_deref())
    }
}

/// Arguments for `harness setup capabilities`.
#[derive(Debug, Clone, Args)]
pub struct CapabilitiesArgs {
    /// Project directory to evaluate for wrapper and plugin readiness.
    #[arg(long)]
    pub project_dir: Option<String>,
}

/// Report harness capabilities as structured JSON for skill planning.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capabilities(project_dir: Option<&str>) -> Result<i32, CliError> {
    let caps = build_report(project_dir);
    let output = serde_json::to_string_pretty(&caps)
        .map_err(|e| CliErrorKind::io(format!("json serialize: {e}")))?;
    println!("{output}");
    Ok(0)
}

fn build_report(project_dir: Option<&str>) -> CapabilitiesReport {
    build_report_with_probe(project_dir, &readiness::SystemProbe)
}

fn build_report_with_probe(
    project_dir: Option<&str>,
    probe: &dyn readiness::CapabilityProbe,
) -> CapabilitiesReport {
    let feature_map = features();
    let readiness = readiness::evaluate(project_dir, &feature_map, probe);
    CapabilitiesReport {
        features: feature_map,
        readiness,
    }
}

#[cfg(test)]
mod tests;
