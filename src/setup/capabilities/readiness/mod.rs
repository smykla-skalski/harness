use std::collections::BTreeMap;
use std::env;
use std::path::PathBuf;

use crate::workspace::dirs_home;

use super::model::{Feature, FeatureInfo, ReadinessReport};

mod checks;
mod scope;
mod summaries;

use checks::build_checks;
use scope::{build_scope, resolve_scope_path};
use summaries::{FeatureReadinessInputs, build_summaries, feature_summary};

#[cfg(test)]
pub(super) use summaries::{BOOTSTRAP_REQUIREMENTS, PROJECT_REQUIREMENTS};

pub(super) trait CapabilityProbe {
    fn path_env(&self) -> String;
    fn home_dir(&self) -> PathBuf;
}

#[derive(Debug, Clone, Copy)]
pub(super) struct SystemProbe;

impl CapabilityProbe for SystemProbe {
    fn path_env(&self) -> String {
        env::var("PATH").unwrap_or_default()
    }

    fn home_dir(&self) -> PathBuf {
        dirs_home()
    }
}

pub(super) fn evaluate(
    raw_project_dir: Option<&str>,
    feature_map: &BTreeMap<Feature, FeatureInfo>,
    probe: &dyn CapabilityProbe,
) -> ReadinessReport {
    let cwd = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let project_dir = resolve_scope_path(raw_project_dir, &cwd);

    let scope = build_scope(&cwd, &project_dir, raw_project_dir.is_some());
    let checks = build_checks(&project_dir, probe);
    let statuses = checks
        .iter()
        .map(|check| (check.code.as_str(), check.status))
        .collect::<BTreeMap<_, _>>();
    let summaries = build_summaries(&statuses);
    let feature_inputs = FeatureReadinessInputs {
        project: &summaries.project,
        bootstrap: &summaries.bootstrap,
    };
    let features = feature_map
        .keys()
        .copied()
        .map(|feature| (feature, feature_summary(feature, &feature_inputs)))
        .collect();

    ReadinessReport {
        scope,
        checks,
        features,
    }
}
