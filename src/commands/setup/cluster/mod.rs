mod kubernetes;
mod universal;

use std::collections::HashMap;
use std::path::Path;

use clap::Args;

use tracing::{debug, info};

use crate::cluster::{ClusterSpec, Platform};
use crate::commands::{CommandContext, Execute};
use crate::context::RunRepository;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec::{run_command, run_command_streaming};
use crate::io::write_json_pretty;

use kubernetes::cluster_k8s;
use universal::cluster_universal;

impl Execute for ClusterArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        cluster(self)
    }
}

/// Arguments for `harness cluster`.
#[derive(Debug, Clone, Args)]
pub struct ClusterArgs {
    /// Cluster lifecycle mode.
    #[arg(value_parser = [
        "single-up", "single-down",
        "global-zone-up", "global-zone-down",
        "global-two-zones-up", "global-two-zones-down",
    ])]
    pub mode: String,
    /// Primary cluster name.
    pub cluster_name: String,
    /// Additional cluster or zone names required by the mode.
    pub extra_cluster_names: Vec<String>,
    /// Deployment platform: kubernetes or universal.
    #[arg(long, default_value = "kubernetes")]
    pub platform: String,
    /// Repo root to run local Kuma build and deploy targets.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Run directory to update deployment state for.
    #[arg(long)]
    pub run_dir: Option<String>,
    /// Extra Helm setting for Kuma deployment; repeat as needed.
    #[arg(long)]
    pub helm_setting: Vec<String>,
    /// Namespace whose workloads to restart after deployment; repeat as needed.
    #[arg(long)]
    pub restart_namespace: Vec<String>,
    /// Store backend for universal mode: memory or postgres.
    #[arg(long, default_value = "memory")]
    pub store: String,
    /// CP container image override for universal mode.
    #[arg(long)]
    pub image: Option<String>,
    /// Skip building images (replaces `HARNESS_BUILD_IMAGES=0`).
    #[arg(long, default_value_t = false)]
    pub no_build: bool,
    /// Skip loading images into k3d clusters (replaces `HARNESS_LOAD_IMAGES=0`).
    #[arg(long, default_value_t = false)]
    pub no_load: bool,
}

fn make_target(root: &Path, target: &str, env: &HashMap<String, String>) -> Result<(), CliError> {
    run_command(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

fn make_target_live(
    root: &Path,
    target: &str,
    env: &HashMap<String, String>,
) -> Result<(), CliError> {
    run_command_streaming(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

/// Manage disposable local clusters (k3d or universal Docker).
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster(args: &ClusterArgs) -> Result<i32, CliError> {
    let platform: Platform = args
        .platform
        .parse()
        .map_err(|e: String| CliError::from(CliErrorKind::usage_error(e)))?;

    match platform {
        Platform::Kubernetes => cluster_k8s(args),
        Platform::Universal => cluster_universal(args),
    }
}

/// Persist cluster spec to the session context and run directory if available.
fn persist_cluster_spec(spec: &ClusterSpec) -> Result<(), CliError> {
    // Update session context (current-run.json) if it exists
    let repo = RunRepository;
    if let Some(pointer) = repo.load_current_pointer()? {
        let run_dir = pointer.layout.run_dir();
        let _ = repo.update_current_pointer(|record| {
            record.cluster = Some(spec.clone());
        })?;

        // Also write to run dir state/cluster.json
        let state_dir = run_dir.join("state");
        if state_dir.is_dir() {
            let cluster_path = state_dir.join("cluster.json");
            write_json_pretty(&cluster_path, spec)?;
            info!("spec saved to state/cluster.json");
        }
    }

    // Always output spec JSON to stdout for scripting
    let spec_json = serde_json::to_string_pretty(&spec.to_json_dict())
        .map_err(|e| CliErrorKind::serialize(cow!("cluster spec json: {e}")))?;
    debug!("{spec_json}");

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;
    use std::fs;
    use std::path::Path;

    use super::universal::{
        KUMA_CP_IMAGE_FILTERS, load_persisted_cluster_spec, resolve_cp_image,
        resolve_effective_store,
    };

    /// Compute the same scope key the production code uses for a given session ID.
    fn scope_key_for_session(session_id: &str) -> String {
        use sha2::{Digest, Sha256};
        let scope = format!("session:{session_id}");
        let mut hasher = Sha256::new();
        hasher.update(scope.as_bytes());
        let hash = hasher.finalize();
        let digest = hash
            .iter()
            .take(8)
            .fold(String::with_capacity(16), |mut acc, byte| {
                let _ = write!(acc, "{byte:02x}");
                acc
            });
        format!("session-{digest}")
    }

    fn write_context_file(xdg_dir: &Path, session_id: &str, content: &str) {
        let scope = scope_key_for_session(session_id);
        let ctx_dir = xdg_dir.join("kuma").join("contexts").join(scope);
        fs::create_dir_all(&ctx_dir).unwrap();
        fs::write(ctx_dir.join("current-run.json"), content).unwrap();
    }

    // --- resolve_effective_store tests ---

    #[test]
    fn effective_store_uses_cli_arg_for_up() {
        let tmp = tempfile::tempdir().unwrap();
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("eff-store-up")),
            ],
            || resolve_effective_store(true, "postgres"),
        );
        assert_eq!(result, "postgres");
    }

    #[test]
    fn effective_store_uses_persisted_for_down() {
        let tmp = tempfile::tempdir().unwrap();
        let session_id = "eff-store-down";
        let record = serde_json::json!({
            "layout": { "run_root": "/tmp/runs", "run_id": "r1" },
            "cluster": {
                "mode": "single-up",
                "platform": "universal",
                "mode_args": ["cp"],
                "members": [{"name": "cp", "role": "cp", "kubeconfig": ""}],
                "helm_settings": [],
                "restart_namespaces": [],
                "repo_root": "/r",
                "store_type": "postgres"
            }
        });
        write_context_file(
            tmp.path(),
            session_id,
            &serde_json::to_string(&record).unwrap(),
        );
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some(session_id)),
            ],
            || resolve_effective_store(false, "memory"),
        );
        assert_eq!(result, "postgres");
    }

    #[test]
    fn effective_store_falls_back_to_cli_for_down() {
        let tmp = tempfile::tempdir().unwrap();
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("eff-store-fallback")),
            ],
            || resolve_effective_store(false, "memory"),
        );
        assert_eq!(result, "memory");
    }

    // --- load_persisted_cluster_spec tests ---

    #[test]
    fn load_persisted_spec_none_when_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("load-test-missing")),
            ],
            load_persisted_cluster_spec,
        );
        assert!(result.unwrap().is_none());
    }

    #[test]
    fn load_persisted_spec_err_when_corrupt() {
        let tmp = tempfile::tempdir().unwrap();
        let session_id = "load-test-corrupt";
        write_context_file(tmp.path(), session_id, "not valid json {{{{");
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some(session_id)),
            ],
            load_persisted_cluster_spec,
        );
        assert!(result.is_err());
    }

    #[test]
    fn load_persisted_spec_returns_cluster() {
        let tmp = tempfile::tempdir().unwrap();
        let session_id = "load-test-valid";
        let record = serde_json::json!({
            "layout": { "run_root": "/tmp/runs", "run_id": "r1" },
            "cluster": {
                "mode": "single-up",
                "platform": "universal",
                "mode_args": ["cp"],
                "members": [{"name": "cp", "role": "cp", "kubeconfig": ""}],
                "helm_settings": [],
                "restart_namespaces": [],
                "repo_root": "/r",
                "store_type": "postgres"
            }
        });
        write_context_file(
            tmp.path(),
            session_id,
            &serde_json::to_string(&record).unwrap(),
        );
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some(session_id)),
            ],
            load_persisted_cluster_spec,
        );
        let spec = result.unwrap().expect("should load cluster spec");
        assert_eq!(spec.store_type.as_deref(), Some("postgres"));
    }

    // --- image filter tests ---

    #[test]
    fn kuma_cp_image_filters_include_glob_pattern() {
        // The glob filter must come first so namespaced images like
        // kumahq/kuma-cp are found before trying the bare name.
        assert!(KUMA_CP_IMAGE_FILTERS[0].contains('*'));
        assert_eq!(KUMA_CP_IMAGE_FILTERS[0], "reference=*kuma-cp");
    }

    #[test]
    fn kuma_cp_image_filters_include_bare_name() {
        assert!(KUMA_CP_IMAGE_FILTERS.contains(&"reference=kuma-cp"));
    }

    #[test]
    fn resolve_cp_image_returns_explicit_image() {
        let tmp = tempfile::tempdir().unwrap();
        let result = resolve_cp_image(tmp.path(), Some("my-registry/kuma-cp:v1.0"), false);
        assert_eq!(result.unwrap(), "my-registry/kuma-cp:v1.0");
    }

    #[test]
    fn resolve_cp_image_returns_explicit_even_with_skip_build() {
        let tmp = tempfile::tempdir().unwrap();
        let result = resolve_cp_image(tmp.path(), Some("kumahq/kuma-cp:latest"), true);
        assert_eq!(result.unwrap(), "kumahq/kuma-cp:latest");
    }
}
