use std::collections::BTreeMap;

use crate::setup::capabilities::model::{Feature, ReadinessStatus, ReadinessSummary};

pub(super) struct CapabilitySummaries {
    pub(super) project: ReadinessSummary,
    pub(super) bootstrap: ReadinessSummary,
}

const PROJECT_REQUIREMENTS: &[&str] = &["project_dir_exists", "wrapper_install_target_available"];
const BOOTSTRAP_REQUIREMENTS: &[&str] = &["project_dir_exists", "wrapper_install_target_available"];

pub(super) fn build_summaries(statuses: &BTreeMap<&str, ReadinessStatus>) -> CapabilitySummaries {
    CapabilitySummaries {
        project: summary_from_codes(statuses, PROJECT_REQUIREMENTS),
        bootstrap: summary_from_codes(statuses, BOOTSTRAP_REQUIREMENTS),
    }
}

fn summary_from_codes(
    statuses: &BTreeMap<&str, ReadinessStatus>,
    codes: &[&str],
) -> ReadinessSummary {
    let ready = codes
        .iter()
        .all(|code| statuses.get(code).copied() == Some(ReadinessStatus::Pass));
    let blocking_checks = codes
        .iter()
        .filter(|code| statuses.get(**code).copied() == Some(ReadinessStatus::Fail))
        .map(|code| (*code).to_string())
        .collect();
    ReadinessSummary {
        ready,
        blocking_checks,
    }
}

pub(super) struct FeatureReadinessInputs<'a> {
    pub(super) project: &'a ReadinessSummary,
    pub(super) bootstrap: &'a ReadinessSummary,
}

pub(super) fn feature_summary(
    feature: Feature,
    inputs: &FeatureReadinessInputs<'_>,
) -> ReadinessSummary {
    match feature {
        Feature::Bootstrap => inputs.bootstrap.clone(),
        Feature::HookSystem
        | Feature::Observation
        | Feature::PreCompactHandoff
        | Feature::SessionLifecycle => inputs.project.clone(),
        Feature::GlobalDelay | Feature::ProgressHeartbeat => ReadinessSummary {
            ready: true,
            blocking_checks: vec![],
        },
    }
}
