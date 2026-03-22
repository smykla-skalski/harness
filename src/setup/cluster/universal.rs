use std::sync::Arc;

#[path = "universal/config.rs"]
mod config;
#[path = "universal/runtime.rs"]
mod runtime;

use tracing::info;

use crate::app::command_context::resolve_repo_root;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{StdProcessExecutor, container_backends_from_env};
use crate::kernel::topology::{ClusterSpec, Platform};
use crate::setup::services::cluster::persist_cluster_spec;

use super::ClusterArgs;

#[cfg(test)]
pub(super) use config::{
    KUMA_CP_IMAGE_FILTERS, load_persisted_cluster_spec, resolve_cp_image, resolve_effective_store,
};
use runtime::{UniversalModeContext, execute_universal_mode};

pub(crate) fn cluster_universal(args: &ClusterArgs) -> Result<i32, CliError> {
    let mode = &args.mode;
    let mut all_names = vec![args.cluster_name.clone()];
    all_names.extend(args.extra_cluster_names.iter().cloned());

    let root = resolve_repo_root(args.repo_root.as_deref());

    let mut spec = ClusterSpec::from_mode_with_platform(
        mode,
        &all_names,
        &root.to_string_lossy(),
        vec![],
        vec![],
        Platform::Universal,
    )
    .map_err(|e| CliError::from(CliErrorKind::cluster_error(e)))?;

    let network_name = spec
        .docker_network
        .clone()
        .unwrap_or_else(|| "harness-default".to_string());
    let is_up = spec.mode.is_up();

    let effective_store = config::resolve_effective_store(is_up, &args.store);
    let cp_image =
        config::resolve_universal_cp_image(is_up, &root, args.image.as_deref(), args.no_build)?;
    let process = Arc::new(StdProcessExecutor);
    let runtimes = container_backends_from_env(process)?;

    info!(%mode, names = %all_names.join(" "), "starting universal cluster");

    execute_universal_mode(
        &UniversalModeContext {
            mode: spec.mode,
            all_names: &all_names,
            network_name: &network_name,
            effective_store: &effective_store,
            cp_image: &cp_image,
        },
        &mut spec,
        runtimes.container_runtime.as_ref(),
        runtimes.compose_orchestrator.as_ref(),
    )?;

    if is_up {
        persist_cluster_spec(&spec)?;
    }

    println!("{mode} completed");
    Ok(0)
}
