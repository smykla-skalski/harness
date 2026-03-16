use std::env;
use std::path::{Path, PathBuf};

use crate::cluster::Platform;
use crate::context::RunContext;
use crate::core_defs::harness_data_root;
use crate::suite_defaults::default_repo_root_for_suite;

/// Resolve the repo root for `init` when not explicitly provided.
pub(crate) fn resolve_init_repo_root(raw: Option<&str>, suite_dir: &Path) -> PathBuf {
    if let Some(r) = raw {
        return PathBuf::from(r)
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(r));
    }
    if let Some(default) = default_repo_root_for_suite(suite_dir) {
        return default;
    }
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Resolve the run root for `init` when not explicitly provided.
pub(crate) fn resolve_run_root(raw: Option<&str>) -> PathBuf {
    raw.map_or_else(|| harness_data_root().join("runs"), PathBuf::from)
}

/// Detect the runtime platform from the run context.
pub(crate) fn detect_platform(ctx: &RunContext) -> Platform {
    if let Some(ref spec) = ctx.cluster {
        return spec.platform;
    }
    if ctx.metadata.profile.contains("universal") {
        return Platform::Universal;
    }
    Platform::Kubernetes
}
