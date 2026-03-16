use std::fs;
use std::io::{self, Read as _};
use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::cluster::Platform;
use crate::commands::{resolve_admin_token, resolve_cp_addr, resolve_kubeconfig, resolve_run_dir};
use crate::context::RunContext;
use crate::core_defs::{shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec;
use crate::exec::kubectl;
use crate::io::{append_markdown_row, ensure_dir, write_text};
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
        let manifest = if manifest_raw == "-" {
            materialize_stdin(&run_dir, step)?
        } else {
            resolve_manifest_path(manifest_raw, Some(&run_dir))?
        };
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

/// Read stdin and write to a temporary manifest file in the run's manifests dir.
fn materialize_stdin(run_dir: &PathBuf, step: Option<&str>) -> Result<PathBuf, CliError> {
    let mut content = String::new();
    io::stdin()
        .read_to_string(&mut content)
        .map_err(|e| CliErrorKind::io(cow!("read stdin: {e}")))?;
    if content.trim().is_empty() {
        return Err(CliErrorKind::usage_error("stdin manifest is empty").into());
    }
    let manifests_dir = run_dir.join("manifests");
    ensure_dir(&manifests_dir)?;
    let name = step.unwrap_or("stdin");
    let path = manifests_dir.join(format!("{name}.yaml"));
    write_text(&path, &content)?;
    Ok(path)
}

/// Build the Kuma REST API path for a resource.
///
/// Kuma endpoints use lowercased type names without separators as the
/// collection segment. For example, `MeshTrafficPermission` maps to
/// `/meshes/{mesh}/meshtrafficpermissions/{name}`.
///
/// The `Mesh` type itself is a special case - it lives at `/meshes/{name}`
/// since it has no mesh scope.
fn kuma_api_path(resource_type: &str, name: &str, mesh: Option<&str>) -> String {
    let collection = resource_type.to_lowercase();

    // The Mesh resource lives at the top level
    if collection == "mesh" {
        return format!("/meshes/{name}");
    }

    let mesh_name = mesh.unwrap_or("default");
    format!("/meshes/{mesh_name}/{collection}s/{name}")
}

fn apply_universal(ctx: &RunContext, manifest: &str) -> Result<(), CliError> {
    let cp_addr = resolve_cp_addr(ctx)?;
    let admin_token = resolve_admin_token(ctx)?;

    // Try REST API first - parse manifest YAML and PUT to CP
    let content = fs::read_to_string(manifest)
        .map_err(|e| CliErrorKind::io(cow!("read manifest {manifest}: {e}")))?;
    let resource: serde_json::Value = serde_yml::from_str(&content)
        .map_err(|e| CliErrorKind::io(cow!("parse manifest {manifest}: {e}")))?;

    if let (Some(resource_type), Some(name)) =
        (resource["type"].as_str(), resource["name"].as_str())
    {
        let mesh = resource["mesh"].as_str();
        let path = kuma_api_path(resource_type, name, mesh);
        let result = exec::cp_api_json(
            &cp_addr,
            &path,
            exec::HttpMethod::Put,
            Some(&resource),
            admin_token.as_deref(),
        );
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kuma_api_path_mesh_resource() {
        assert_eq!(kuma_api_path("Mesh", "my-mesh", None), "/meshes/my-mesh");
        assert_eq!(
            kuma_api_path("Mesh", "default", Some("ignored")),
            "/meshes/default"
        );
    }

    #[test]
    fn kuma_api_path_mesh_scoped_policy() {
        assert_eq!(
            kuma_api_path("MeshTrafficPermission", "allow-all", Some("default")),
            "/meshes/default/meshtrafficpermissions/allow-all"
        );
    }

    #[test]
    fn kuma_api_path_simple_type() {
        assert_eq!(
            kuma_api_path("Dataplane", "dp-1", Some("default")),
            "/meshes/default/dataplanes/dp-1"
        );
    }

    #[test]
    fn kuma_api_path_defaults_to_default_mesh() {
        assert_eq!(
            kuma_api_path("MeshTimeout", "mt-1", None),
            "/meshes/default/meshtimeouts/mt-1"
        );
    }
}
