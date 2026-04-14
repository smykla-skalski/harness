use std::collections::BTreeMap;
use std::env;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::infra::blocks::BollardContainerRuntime;
use crate::workspace::dirs_home;

use super::model::{Feature, FeatureInfo, ReadinessReport};

mod checks;
mod repo;
mod scope;
mod summaries;

use checks::{build_checks, command_on_path};
use scope::{auto_detect_kuma_repo_root, build_scope, resolve_scope_path};
use summaries::{
    FeatureReadinessInputs, build_platform_readiness, build_profile_readiness,
    build_provider_readiness, build_summaries, feature_summary,
};

pub(super) trait CapabilityProbe {
    fn path_env(&self) -> String;
    fn home_dir(&self) -> PathBuf;
    fn command_on_path(&self, command: &str) -> bool;
    fn run_command_success(&self, program: &str, args: &[&str]) -> bool;
    fn docker_engine_reachable(&self) -> bool;
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

    fn command_on_path(&self, command: &str) -> bool {
        command_on_path(command, &self.path_env())
    }

    fn run_command_success(&self, program: &str, args: &[&str]) -> bool {
        Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    fn docker_engine_reachable(&self) -> bool {
        BollardContainerRuntime::daemon_reachable()
    }
}

pub(super) fn evaluate(
    raw_project_dir: Option<&str>,
    raw_repo_root: Option<&str>,
    feature_map: &BTreeMap<Feature, FeatureInfo>,
    probe: &dyn CapabilityProbe,
) -> ReadinessReport {
    let cwd = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let project_dir = resolve_scope_path(raw_project_dir, &cwd);
    let repo_root = raw_repo_root
        .map(|raw| resolve_scope_path(Some(raw), &cwd))
        .or_else(|| auto_detect_kuma_repo_root(&project_dir));

    let scope = build_scope(
        &cwd,
        &project_dir,
        repo_root.as_deref(),
        raw_project_dir.is_some(),
        raw_repo_root.is_some(),
    );
    let checks = build_checks(&project_dir, repo_root.as_deref(), probe);
    let statuses = checks
        .iter()
        .map(|check| (check.code.as_str(), check.status))
        .collect::<BTreeMap<_, _>>();
    let summaries = build_summaries(&statuses);
    let feature_inputs = FeatureReadinessInputs {
        project: &summaries.project,
        bootstrap: &summaries.bootstrap,
        repo: &summaries.repo,
        kubernetes: &summaries.kubernetes,
        universal: &summaries.universal,
        either_platform: &summaries.either_platform,
    };
    let features = feature_map
        .keys()
        .copied()
        .map(|feature| (feature, feature_summary(feature, &feature_inputs)))
        .collect();

    ReadinessReport {
        scope,
        checks,
        create: summaries.create.clone(),
        platforms: build_platform_readiness(&summaries),
        providers: build_provider_readiness(&summaries),
        features,
        profiles: build_profile_readiness(&summaries),
    }
}
