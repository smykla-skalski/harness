use std::fs;
use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::cluster::Platform;
use crate::commands::{resolve_admin_token, resolve_cp_addr, resolve_kubeconfig, resolve_run_dir};
use crate::context::RunContext;
use crate::core_defs::{shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec;
use crate::exec::kubectl;
use crate::io::append_markdown_row;
use crate::resolve::resolve_manifest_path;

use super::kumactl::find_kumactl_binary;
use super::shared::detect_platform;

/// Apply manifests to the cluster.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn apply(
    kubeconfig: Option<&str>,
    cluster_arg: Option<&str>,
    manifests: &[String],
    step: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;
    let ctx = RunContext::from_run_dir(&run_dir)?;
    let platform = detect_platform(&ctx);

    for manifest_raw in manifests {
        let manifest = resolve_manifest_path(manifest_raw, Some(&run_dir))?;
        let manifest_str = manifest.to_string_lossy().into_owned();

        match platform {
            Platform::Kubernetes => {
                let kc = resolve_kubeconfig(&ctx, kubeconfig, cluster_arg)?;
                kubectl(Some(&kc), &["apply", "-f", &manifest_str], &[0])?;
            }
            Platform::Universal => {
                apply_universal(&ctx, &manifest_str)?;
            }
        }

        let manifest_index = ctx.layout.manifests_dir().join("manifest-index.md");
        let rel = manifest.strip_prefix(ctx.layout.run_dir()).map_or_else(
            |_| manifest.display().to_string(),
            |p| p.display().to_string(),
        );
        let notes = step.map_or_else(String::new, |s| format!("{s}: "));
        append_markdown_row(
            &manifest_index,
            &["copied_at", "manifest", "validated", "applied", "notes"],
            &[&utc_now(), &rel, "PASS", "PASS", &notes],
        )?;
        println!("{}", shorten_path(&manifest));
    }
    Ok(0)
}

fn apply_universal(ctx: &RunContext, manifest: &str) -> Result<(), CliError> {
    let cp_addr = resolve_cp_addr(ctx)?;
    let admin_token = resolve_admin_token(ctx)?;

    // Try REST API first - parse manifest YAML and PUT to CP
    let content = fs::read_to_string(manifest)
        .map_err(|e| CliErrorKind::io(cow!("read manifest {manifest}: {e}")))?;
    let resource: serde_json::Value = serde_yml::from_str(&content)
        .map_err(|e| CliErrorKind::io(cow!("parse manifest {manifest}: {e}")))?;

    if let (Some(resource_type), Some(name), Some(mesh)) = (
        resource["type"].as_str(),
        resource["name"].as_str(),
        resource["mesh"].as_str(),
    ) {
        let path = format!(
            "/meshes/{mesh}/{resource_type}s/{name}",
            resource_type = resource_type.to_lowercase()
        );
        let result =
            exec::cp_api_put_with_token(&cp_addr, &path, &resource, admin_token.as_deref());
        if result.is_ok() {
            return Ok(());
        }
        eprintln!("apply: REST API failed, falling back to kumactl");
    }

    // Fallback to kumactl
    let root = PathBuf::from(&ctx.metadata.repo_root);
    let binary = find_kumactl_binary(&root)?;
    exec::kumactl_run(&binary, &cp_addr, &["apply", "-f", manifest], &[0])?;
    Ok(())
}
