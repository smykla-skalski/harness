use std::path::Path;
use std::sync::Arc;

#[path = "universal/config.rs"]
mod config;
#[path = "universal/runtime.rs"]
mod runtime;

use crate::app::command_context::resolve_repo_root;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{
    ComposeOrchestrator, ContainerRuntime, StdProcessExecutor, container_backends_from_env,
};
use crate::kernel::topology::{ClusterSpec, Platform};
use crate::setup::services::cluster::persist_cluster_spec;

use super::ClusterArgs;

#[cfg(test)]
pub(super) use config::{
    KUMA_CP_IMAGE_FILTERS, load_persisted_cluster_spec, resolve_cp_image, resolve_effective_store,
};
use runtime::{UniversalModeContext, execute_universal_mode};

type UniversalRuntimes = (Arc<dyn ContainerRuntime>, Arc<dyn ComposeOrchestrator>);

pub(crate) fn cluster_universal(args: &ClusterArgs) -> Result<i32, CliError> {
    let mode = &args.mode;
    let all_names = universal_cluster_names(args);
    let root = resolve_repo_root(args.repo_root.as_deref());
    let mut spec = build_universal_spec(mode, &all_names, &root)?;
    let network_name = universal_network_name(&spec);
    let is_up = spec.mode.is_up();
    let effective_store = config::resolve_effective_store(is_up, &args.store);
    let cp_image =
        config::resolve_universal_cp_image(is_up, &root, args.image.as_deref(), args.no_build)?;
    let (container_runtime, compose_orchestrator) = universal_runtimes()?;
    execute_universal_mode(
        &UniversalModeContext {
            mode: spec.mode,
            all_names: &all_names,
            network_name: &network_name,
            effective_store: &effective_store,
            cp_image: &cp_image,
        },
        &mut spec,
        container_runtime.as_ref(),
        compose_orchestrator.as_ref(),
    )?;
    persist_universal_spec_if_needed(is_up, &spec)?;
    println!("{mode} completed");
    Ok(0)
}

fn universal_cluster_names(args: &ClusterArgs) -> Vec<String> {
    let mut all_names = vec![args.cluster_name.clone()];
    all_names.extend(args.extra_cluster_names.iter().cloned());
    all_names
}

fn build_universal_spec(
    mode: &str,
    all_names: &[String],
    root: &Path,
) -> Result<ClusterSpec, CliError> {
    ClusterSpec::from_mode_with_platform(
        mode,
        all_names,
        &root.to_string_lossy(),
        vec![],
        vec![],
        Platform::Universal,
    )
    .map_err(|e| CliError::from(CliErrorKind::cluster_error(e)))
}

fn universal_network_name(spec: &ClusterSpec) -> String {
    spec.docker_network
        .clone()
        .unwrap_or_else(|| "harness-default".to_string())
}

fn universal_runtimes() -> Result<UniversalRuntimes, CliError> {
    let process = Arc::new(StdProcessExecutor);
    let runtimes = container_backends_from_env(process)?;
    Ok((runtimes.container_runtime, runtimes.compose_orchestrator))
}

fn persist_universal_spec_if_needed(is_up: bool, spec: &ClusterSpec) -> Result<(), CliError> {
    if is_up {
        persist_cluster_spec(spec)?;
    }
    Ok(())
}
