use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};

#[path = "capabilities/data.rs"]
mod data;
#[path = "capabilities/model.rs"]
mod model;
#[path = "capabilities/readiness.rs"]
mod readiness;

use data::{cluster_topologies, create, features, platforms, providers};
use model::CapabilitiesReport;

impl Execute for CapabilitiesArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        capabilities(self.project_dir.as_deref(), self.repo_root.as_deref())
    }
}

/// Arguments for `harness setup capabilities`.
#[derive(Debug, Clone, Args)]
pub struct CapabilitiesArgs {
    /// Project directory to evaluate for wrapper and plugin readiness.
    #[arg(long)]
    pub project_dir: Option<String>,
    /// Kuma repository root to evaluate for active cluster support.
    #[arg(long)]
    pub repo_root: Option<String>,
}

/// Report harness capabilities as structured JSON for skill planning.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capabilities(project_dir: Option<&str>, repo_root: Option<&str>) -> Result<i32, CliError> {
    let caps = build_report(project_dir, repo_root);
    let output = serde_json::to_string_pretty(&caps)
        .map_err(|e| CliErrorKind::io(format!("json serialize: {e}")))?;
    println!("{output}");
    Ok(0)
}

fn build_report(project_dir: Option<&str>, repo_root: Option<&str>) -> CapabilitiesReport {
    build_report_with_probe(project_dir, repo_root, &readiness::SystemProbe)
}

fn build_report_with_probe(
    project_dir: Option<&str>,
    repo_root: Option<&str>,
    probe: &dyn readiness::CapabilityProbe,
) -> CapabilitiesReport {
    let feature_map = features();
    let readiness = readiness::evaluate(project_dir, repo_root, &feature_map, probe);
    CapabilitiesReport {
        create: create(),
        cluster_topologies: cluster_topologies(),
        features: feature_map,
        platforms: platforms(),
        providers: providers(),
        readiness,
    }
}

#[cfg(test)]
mod tests;
